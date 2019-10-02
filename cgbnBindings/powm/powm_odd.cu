/***

Copyright (c) 2018-2019, NVIDIA CORPORATION.  All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

***/

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <cuda.h>
#include <cuda_profiler_api.h>
#include <gmp.h>
#include "cgbn/cgbn.h"
#include "../utility/support.h"
#include "powm_odd_export.h"

// For this example, there are quite a few template parameters that are used to generate the actual code.
// In order to simplify passing many parameters, we use the same approach as the CGBN library, which is to
// create a container class with static constants and then pass the class.

// The CGBN context uses the following three parameters:
//   TBP             - threads per block (zero means to use the blockDim.x)
//   MAX_ROTATION    - must be small power of 2, imperically, 4 works well
//   SHM_LIMIT       - number of bytes of dynamic shared memory available to the kernel
//   CONSTANT_TIME   - require constant time algorithms (currently, constant time algorithms are not available)

// Locally it will also be helpful to have several parameters:
//   TPI             - threads per instance
//   BITS            - number of bits per instance
//   WINDOW_BITS     - number of bits to use for the windowed exponentiation

template<uint32_t tpi, uint32_t bits, uint32_t window_bits>
class powm_params_t {
  public:
  // parameters used by the CGBN context
  static const uint32_t TPB=0;                     // get TPB from blockDim.x  
  static const uint32_t MAX_ROTATION=4;            // good default value
  static const uint32_t SHM_LIMIT=0;               // no shared mem available
  static const bool     CONSTANT_TIME=false;       // constant time implementations aren't available yet
  
  // parameters used locally in the application
  static const uint32_t TPI=tpi;                   // threads per instance
  static const uint32_t BITS=bits;                 // instance size
  static const uint32_t WINDOW_BITS=window_bits;   // window size
};

template<class params>
class powm_odd_t {
  public:
  static const uint32_t window_bits=params::WINDOW_BITS;  // used a lot, give it an instance variable

  // It might be possible to switch to a SOA structure within the instance_t struct
  // Currently, I believe removing this struct completely would make things worse
  // The main advantage of the current interleaved AOS input structure is that it allows making the 
  // input memory longer by concatenating byte arrays that represent valid inputs
  // I also need to run benchmarks on an x16 pcie link to make sure we're making the correct pcie bandwidth tradeoff
  // Results shouldn't belong in the instance struct. They should get allocated and written separately, so as to not
  // have to download and uploaded more than is necessary. x and pow should only be uploaded, and results should only
  // be downloaded.
  typedef struct {
    cgbn_mem_t<params::BITS> x;
    cgbn_mem_t<params::BITS> power;
  } input_t;
  
  typedef cgbn_context_t<params::TPI, params>   context_t;
  typedef cgbn_env_t<context_t, params::BITS>   env_t;
  typedef typename env_t::cgbn_t                bn_t;
  typedef typename env_t::cgbn_local_t          bn_local_t;

  context_t _context;
  env_t     _env;
  int32_t   _instance;

  __device__ __forceinline__ powm_odd_t(cgbn_monitor_t monitor, cgbn_error_report_t *report, int32_t instance) : _context(monitor, report, (uint32_t)instance), _env(_context), _instance(instance) {
  }

  __device__ __forceinline__ void fixed_window_powm_odd(bn_t &result, const bn_t &x, const bn_t &power, const bn_t &modulus) {
    bn_t       t;
    bn_local_t window[1<<window_bits];
    int32_t    index, position, offset;
    uint32_t   np0;

    // conmpute x^power mod modulus, using the fixed window algorithm
    // requires:  x<modulus,  modulus is odd

    // compute x^0 (in Montgomery space, this is just 2^BITS - modulus)
    cgbn_negate(_env, t, modulus);
    cgbn_store(_env, window+0, t);
    
    // convert x into Montgomery space, store into window table
    np0=cgbn_bn2mont(_env, result, x, modulus);
    cgbn_store(_env, window+1, result);
    cgbn_set(_env, t, result);
    
    // compute x^2, x^3, ... x^(2^window_bits-1), store into window table
    #pragma nounroll
    for(index=2;index<(1<<window_bits);index++) {
      cgbn_mont_mul(_env, result, result, t, modulus, np0);
      cgbn_store(_env, window+index, result);
    }

    // find leading high bit
    position=params::BITS - cgbn_clz(_env, power);

    // break the exponent into chunks, each window_bits in length
    // load the most significant non-zero exponent chunk
    offset=position % window_bits;
    if(offset==0)
      position=position-window_bits;
    else
      position=position-offset;
    index=cgbn_extract_bits_ui32(_env, power, position, window_bits);
    cgbn_load(_env, result, window+index);
    
    // process the remaining exponent chunks
    while(position>0) {
      // square the result window_bits times
      #pragma nounroll
      for(int sqr_count=0;sqr_count<window_bits;sqr_count++)
        cgbn_mont_sqr(_env, result, result, modulus, np0);
      
      // multiply by next exponent chunk
      position=position-window_bits;
      index=cgbn_extract_bits_ui32(_env, power, position, window_bits);
      cgbn_load(_env, t, window+index);
      cgbn_mont_mul(_env, result, result, t, modulus, np0);
    }
    
    // we've processed the exponent now, convert back to normal space
    cgbn_mont2bn(_env, result, result, modulus, np0);
  }
  
  __device__ __forceinline__ void sliding_window_powm_odd(bn_t &result, const bn_t &x, const bn_t &power, const bn_t &modulus) {
    bn_t         t, starts;
    int32_t      index, position, leading;
    uint32_t     mont_inv;
    bn_local_t   odd_powers[1<<window_bits-1];

    // compute x^power mod modulus, using Constant Length Non-Zero windows (CLNZ).
    // requires:  x<modulus,  modulus is odd
        
    // find the leading one in the power
    leading=params::BITS-1-cgbn_clz(_env, power);
    if(leading>=0) {
      // convert x into Montgomery space, store in the odd powers table
      mont_inv=cgbn_bn2mont(_env, result, x, modulus);
      
      // compute t=x^2 mod modulus
      cgbn_mont_sqr(_env, t, result, modulus, mont_inv);
      
      // compute odd powers window table: x^1, x^3, x^5, ...
      cgbn_store(_env, odd_powers, result);
      #pragma nounroll
      for(index=1;index<(1<<window_bits-1);index++) {
        cgbn_mont_mul(_env, result, result, t, modulus, mont_inv);
        cgbn_store(_env, odd_powers+index, result);
      }
  
      // starts contains an array of bits indicating the start of a window
      cgbn_set_ui32(_env, starts, 0);
  
      // organize p as a sequence of odd window indexes
      position=0;
      while(true) {
        if(cgbn_extract_bits_ui32(_env, power, position, 1)==0)
          position++;
        else {
          cgbn_insert_bits_ui32(_env, starts, starts, position, 1, 1);
          if(position+window_bits>leading)
            break;
          position=position+window_bits;
        }
      }
  
      // load first window.  Note, since the window index must be odd, we have to
      // divide it by two before indexing the window table.  Instead, we just don't
      // load the index LSB from power
      index=cgbn_extract_bits_ui32(_env, power, position+1, window_bits-1);
      cgbn_load(_env, result, odd_powers+index);
      position--;
      
      // Process remaining windows 
      while(position>=0) {
        cgbn_mont_sqr(_env, result, result, modulus, mont_inv);
        if(cgbn_extract_bits_ui32(_env, starts, position, 1)==1) {
          // found a window, load the index
          index=cgbn_extract_bits_ui32(_env, power, position+1, window_bits-1);
          cgbn_load(_env, t, odd_powers+index);
          cgbn_mont_mul(_env, result, result, t, modulus, mont_inv);
        }
        position--;
      }
      
      // convert result from Montgomery space
      cgbn_mont2bn(_env, result, result, modulus, mont_inv);
    }
    else {
      // p=0, thus x^p mod modulus=1
      cgbn_set_ui32(_env, result, 1);
    }
  }
};

// kernel implementation using cgbn
// 
// Unfortunately, the kernel must be separate from the powm_odd_t class
// kernel_powm_odd<params><<<(instance_count+IPB-1)/IPB, TPB>>>(report, gpuInputs, gpuResults, instance_count);
template<class params>
__global__ void kernel_powm_odd(cgbn_error_report_t *report, typename powm_odd_t<params>::input_t *inputs, cgbn_mem_t<params::BITS> *modulus, cgbn_mem_t<params::BITS> *outputs, uint32_t count) {
  int32_t instance;

  // decode an instance number from the blockIdx and threadIdx
  instance=(blockIdx.x*blockDim.x + threadIdx.x)/params::TPI;
  if(instance>=count)
    return;

  powm_odd_t<params>                 po(cgbn_report_monitor, report, instance);
  typename powm_odd_t<params>::bn_t  r, x, p, m;
  
  // the loads and stores can go in the class, but it seems more natural to have them
  // here and to pass in and out bignums
  cgbn_load(po._env, x, &(inputs[instance].x));
  cgbn_load(po._env, p, &(inputs[instance].power));
  cgbn_load(po._env, m, modulus);
  
  // this can be either fixed_window_powm_odd or sliding_window_powm_odd.
  // when TPI<32, fixed window runs much faster because it is less divergent, so we use it here
  po.fixed_window_powm_odd(r, x, p, m);
  //   OR
  // po.sliding_window_powm_odd(r, x, p, m);
  
  cgbn_store(po._env, &(outputs[instance]), r);
}

// Result of upload_powm
template<class params>
struct powm_upload_results_t {
  // Number of items: instance_count
  typename powm_odd_t<params>::input_t *gpuInputs;
  cgbn_mem_t<params::BITS> *gpuResults;
  // Number of items: 1
  cgbn_mem_t<params::BITS> *gpuModulus;
  uint32_t instance_count;
  cgbn_error_report_t *report;
};

// Check error before proceeding
// Does async memcpy set the error?
// Clean up struct if error is present
// Uploads memory from host to device, asynchronously
// Returns a struct that will contain the necessary parameters to the run function
// FIXME This should be part of the powm class, right?
// Returns error
// Puts resulting valid structure (except in error cases) in last parameter
template<class params>
const char* upload_powm(const void* modulus, const void *inputs, const uint32_t instance_count, powm_upload_results_t<params>* result) {
  typedef typename powm_odd_t<params>::input_t input_t;
  
  // Set instance count; it's re-used when the kernel gets run later
  result->instance_count = instance_count;
  // Initialize fields to null
  // If an error occurs, non-null GPU buffers should be cleaned up by the caller
  
  // Because there aren't multiple return types, this will no longer work
  CUDA_CHECK_RETURN(cudaSetDevice(0));
  printf("Copying inputs to the GPU ...\n");
  // Is this the best way of allocating memory for each kernel launch?
  // Is there actually a perf difference doing things this way vs the AoS allocation style?
  // Results will be written to the end of this area of memory
  // I'm pretty sure this is a dumb way of doing it...
  const size_t modulusSize = sizeof(cgbn_mem_t<params::BITS>);
  const size_t resultsSize = sizeof(cgbn_mem_t<params::BITS>)*instance_count;
  const size_t inputsSize = sizeof(input_t)*instance_count;

 CUDA_CHECK_RETURN(cudaMalloc((void **)&(result->gpuInputs), inputsSize));
  CUDA_CHECK_RETURN(cudaMalloc((void **)&(result->gpuResults), resultsSize));
  CUDA_CHECK_RETURN(cudaMalloc((void **)&(result->gpuModulus), modulusSize));

  CUDA_CHECK_RETURN(cudaMemcpy((void *)result->gpuInputs, inputs, inputsSize, cudaMemcpyHostToDevice));

  // Currently, we're copying to the modulus before each kernel launch
  CUDA_CHECK_RETURN(cudaMemcpy((void *)result->gpuModulus, modulus, modulusSize, cudaMemcpyHostToDevice));

  // create a cgbn_error_report for CGBN to report back errors
  CUDA_CHECK_RETURN(cgbn_error_report_alloc(&(result->report)));

  return NULL;
}

// Run powm kernel
// Blocks until kernel execution finishes, then copies results from device to host
// To call this, you should have prepared a kernel launch with upload_powm
// and waited for the returned struct to be populated
// The method will only work properly with a valid (i.e. non-error) 
// powm_upload_results_t
// The results will be placed in the passed results pointer after the kernel run
template<class params>
const char* run_powm(const powm_upload_results_t<params> *upload, void *results) {
  // TODO Wait on upload event to finish before running kernel
  //  Can't be done until we switch to async uploads
  typedef typename powm_odd_t<params>::input_t input_t;

  const int32_t              TPB=(params::TPB==0) ? 128 : params::TPB;    // default threads per block to 128
  const int32_t              TPI=params::TPI, IPB=TPB/TPI;                // IPB is instances per block

  const size_t resultsSize = sizeof(cgbn_mem_t<params::BITS>)*upload->instance_count;

  // launch kernel with blocks=ceil(instance_count/IPB) and threads=TPB
  // We'll try a launch with just 1 instance, and see if that access is still illegal
  // Probably the memory is not getting uploaded all in one chunk, as it should be.
  kernel_powm_odd<params><<<(upload->instance_count+IPB-1)/IPB, TPB>>>(upload->report, upload->gpuInputs, upload->gpuModulus, upload->gpuResults, upload->instance_count);

  // error report uses managed memory, so we sync the device (or stream) and check for cgbn errors
  // Note: This should probably only happen in debug builds, as the error 
  // report might not be necessary in normal usage
  CUDA_CHECK_RETURN(cudaDeviceSynchronize());
  CGBN_CHECK_RETURN(upload->report);

  // The kernel ran successfully, so we get the results off the GPU
  CUDA_CHECK_RETURN(cudaMemcpy(results, upload->gpuResults, resultsSize, cudaMemcpyDeviceToHost));

  // We don't need these GPU buffers anymore, as the kernel has run
  // Does this free the buffers properly? I have concerns about correctness here
  CUDA_CHECK_RETURN(cudaFree((void*)upload->gpuInputs));
  CUDA_CHECK_RETURN(cudaFree((void*)upload->gpuResults));
  CUDA_CHECK_RETURN(cudaFree((void*)upload->gpuModulus));
  CUDA_CHECK_RETURN(cgbn_error_report_free(upload->report));
  return NULL;
}

typedef powm_params_t<32, 2048, 5> params2048;
typedef powm_params_t<32, 4096, 5> params4096;

template<class params>
inline return_data* powm_export(const powm_upload_results_t<params> *upload) {
  // Run kernel
  return_data *rd = (return_data*)malloc(sizeof(*rd));
  auto result_mem = malloc(sizeof(cgbn_mem_t<params::BITS>) * upload->instance_count);
  rd->error = run_powm<params>(upload, result_mem);
  rd->result = result_mem;
  return rd;
}

template<class params>
inline return_data* upload_export(const void *prime, const void *instances, const uint32_t instance_count) {
  // Upload data
  // TODO Structure this better - upload should return just error, and the
  //  upload results should be passed in and edited by the method
  return_data *rd = (return_data*)malloc(sizeof(*rd));
  auto up = (powm_upload_results_t<params>*)malloc(sizeof(powm_upload_results_t<params>));
  rd->error = upload_powm<params>(prime, instances, instance_count, up);
  if (rd->error == NULL) {
    // Normal case
    rd->result = up;
  } else {
    // Error case
    rd->result = NULL;
    // TODO Free non-null buffers
  }
  return rd;
}

// All the methods used in cgo should have extern "C" linkage to avoid
// implementation-specific name mangling
// This makes them more straightforward to load from the shared object
extern "C" {
  // 2K BITS
  return_data* powm_2048(const void *prime, const void *instances, const uint32_t instance_count) {
    auto rd = upload_export<params2048>(prime, instances, instance_count);
    auto runResult = powm_export<params2048>((powm_upload_results_t<params2048>*)rd->result);
    free(rd->result);
    return runResult;
  }

  // 4K BITS
  return_data* powm_4096(const void *prime, const void *instances, const uint32_t instance_count) {
    auto rd = upload_export<params4096>(prime, instances, instance_count);
    auto runResult = powm_export<params4096>((powm_upload_results_t<params4096>*)rd->result);
    free(rd->result);
    return runResult;
  }

  // Call this after execution has completed to write out profile information to the disk
  const char* stopProfiling() {
    CUDA_CHECK_RETURN(cudaProfilerStop());
    return NULL;
  }

  const char* startProfiling() {
    CUDA_CHECK_RETURN(cudaProfilerStart());
    return NULL;
  }

  const char* resetDevice() {
    CUDA_CHECK_RETURN(cudaDeviceReset());
    return NULL;
  }
}


#ifndef CUDA_INTEGER_CUH
#define CUDA_INTEGER_CUH

#include "crypto/keyswitch.cuh"
#include "device.h"
#include "integer.h"
#include "integer/scalar_addition.cuh"
#include "linear_algebra.h"
#include "linearalgebra/addition.cuh"
#include "polynomial/functions.cuh"
#include "programmable_bootstrap.h"
#include "utils/helper.cuh"
#include "utils/kernel_dimensions.cuh"
#include <functional>

// function rotates right  radix ciphertext with specific value
// grid is one dimensional
// blockIdx.x represents x_th block of radix ciphertext
template <typename Torus>
__global__ void radix_blocks_rotate_right(Torus *dst, Torus *src,
                                          uint32_t value, uint32_t blocks_count,
                                          uint32_t lwe_size) {
  value %= blocks_count;

  size_t tid = threadIdx.x;
  size_t src_block_id = blockIdx.x;
  size_t dst_block_id = (src_block_id + value) % blocks_count;
  size_t stride = blockDim.x;

  auto cur_src_block = &src[src_block_id * lwe_size];
  auto cur_dst_block = &dst[dst_block_id * lwe_size];

  for (size_t i = tid; i < lwe_size; i += stride) {
    cur_dst_block[i] = cur_src_block[i];
  }
}

// function rotates left  radix ciphertext with specific value
// grid is one dimensional
// blockIdx.x represents x_th block of radix ciphertext
template <typename Torus>
__global__ void radix_blocks_rotate_left(Torus *dst, Torus *src, uint32_t value,
                                         uint32_t blocks_count,
                                         uint32_t lwe_size) {
  value %= blocks_count;
  size_t src_block_id = blockIdx.x;

  size_t tid = threadIdx.x;
  size_t dst_block_id = (src_block_id >= value)
                            ? src_block_id - value
                            : src_block_id - value + blocks_count;
  size_t stride = blockDim.x;

  auto cur_src_block = &src[src_block_id * lwe_size];
  auto cur_dst_block = &dst[dst_block_id * lwe_size];

  for (size_t i = tid; i < lwe_size; i += stride) {
    cur_dst_block[i] = cur_src_block[i];
  }
}

// rotate radix ciphertext right with specific value
// calculation is not inplace, so `dst` and `src` must not be the same
template <typename Torus>
__host__ void
host_radix_blocks_rotate_right(cudaStream_t *streams, uint32_t *gpu_indexes,
                               uint32_t gpu_count, Torus *dst, Torus *src,
                               uint32_t value, uint32_t blocks_count,
                               uint32_t lwe_size) {
  if (src == dst) {
    PANIC("Cuda error (blocks_rotate_right): the source and destination "
          "pointers should be different");
  }
  cudaSetDevice(gpu_indexes[0]);
  radix_blocks_rotate_right<<<blocks_count, 256, 0, streams[0]>>>(
      dst, src, value, blocks_count, lwe_size);
}

// rotate radix ciphertext left with specific value
// calculation is not inplace, so `dst` and `src` must not be the same
template <typename Torus>
__host__ void
host_radix_blocks_rotate_left(cudaStream_t *streams, uint32_t *gpu_indexes,
                              uint32_t gpu_count, Torus *dst, Torus *src,
                              uint32_t value, uint32_t blocks_count,
                              uint32_t lwe_size) {
  if (src == dst) {
    PANIC("Cuda error (blocks_rotate_left): the source and destination "
          "pointers should be different");
  }
  cudaSetDevice(gpu_indexes[0]);
  radix_blocks_rotate_left<<<blocks_count, 256, 0, streams[0]>>>(
      dst, src, value, blocks_count, lwe_size);
}

// polynomial_size threads
template <typename Torus>
__global__ void
device_pack_bivariate_blocks(Torus *lwe_array_out, Torus *lwe_indexes_out,
                             Torus *lwe_array_1, Torus *lwe_array_2,
                             Torus *lwe_indexes_in, uint32_t lwe_dimension,
                             uint32_t shift, uint32_t num_blocks) {
  int tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid < num_blocks * (lwe_dimension + 1)) {
    int block_id = tid / (lwe_dimension + 1);
    int coeff_id = tid % (lwe_dimension + 1);

    int pos_in = lwe_indexes_in[block_id] * (lwe_dimension + 1) + coeff_id;
    int pos_out = lwe_indexes_out[block_id] * (lwe_dimension + 1) + coeff_id;
    lwe_array_out[pos_out] = lwe_array_1[pos_in] * shift + lwe_array_2[pos_in];
  }
}

/* Combine lwe_array_1 and lwe_array_2 so that each block m1 and m2
 *  becomes out = m1 * shift + m2
 */
template <typename Torus>
__host__ void pack_bivariate_blocks(cudaStream_t *streams,
                                    uint32_t *gpu_indexes, uint32_t gpu_count,
                                    Torus *lwe_array_out,
                                    Torus *lwe_indexes_out, Torus *lwe_array_1,
                                    Torus *lwe_array_2, Torus *lwe_indexes_in,
                                    uint32_t lwe_dimension, uint32_t shift,
                                    uint32_t num_radix_blocks) {

  cudaSetDevice(gpu_indexes[0]);
  // Left message is shifted
  int num_blocks = 0, num_threads = 0;
  int num_entries = num_radix_blocks * (lwe_dimension + 1);
  getNumBlocksAndThreads(num_entries, 512, num_blocks, num_threads);
  device_pack_bivariate_blocks<<<num_blocks, num_threads, 0, streams[0]>>>(
      lwe_array_out, lwe_indexes_out, lwe_array_1, lwe_array_2, lwe_indexes_in,
      lwe_dimension, shift, num_radix_blocks);
  check_cuda_error(cudaGetLastError());
}

template <typename Torus>
__host__ void integer_radix_apply_univariate_lookup_table_kb(
    cudaStream_t *streams, uint32_t *gpu_indexes, uint32_t gpu_count,
    Torus *lwe_array_out, Torus *lwe_array_in, void *bsk, Torus *ksk,
    uint32_t num_radix_blocks, int_radix_lut<Torus> *lut) {
  // apply_lookup_table
  auto params = lut->params;
  auto pbs_type = params.pbs_type;
  auto big_lwe_dimension = params.big_lwe_dimension;
  auto small_lwe_dimension = params.small_lwe_dimension;
  auto ks_level = params.ks_level;
  auto ks_base_log = params.ks_base_log;
  auto pbs_level = params.pbs_level;
  auto pbs_base_log = params.pbs_base_log;
  auto glwe_dimension = params.glwe_dimension;
  auto polynomial_size = params.polynomial_size;
  auto grouping_factor = params.grouping_factor;

  // Compute Keyswitch-PBS
  cuda_keyswitch_lwe_ciphertext_vector(
      streams[0], gpu_indexes[0], lut->tmp_lwe_after_ks,
      lut->lwe_trivial_indexes, lwe_array_in, lut->lwe_indexes_in, ksk,
      big_lwe_dimension, small_lwe_dimension, ks_base_log, ks_level,
      num_radix_blocks);

  execute_pbs<Torus>(streams, gpu_indexes, gpu_count, lwe_array_out,
                     lut->lwe_indexes_out, lut->lut, lut->lut_indexes,
                     lut->tmp_lwe_after_ks, lut->lwe_trivial_indexes, bsk,
                     lut->buffer, glwe_dimension, small_lwe_dimension,
                     polynomial_size, pbs_base_log, pbs_level, grouping_factor,
                     num_radix_blocks, 1, 0,
                     cuda_get_max_shared_memory(gpu_indexes[0]), pbs_type);
}

template <typename Torus>
__host__ void integer_radix_apply_bivariate_lookup_table_kb(
    cudaStream_t *streams, uint32_t *gpu_indexes, uint32_t gpu_count,
    Torus *lwe_array_out, Torus *lwe_array_1, Torus *lwe_array_2, void *bsk,
    Torus *ksk, uint32_t num_radix_blocks, int_radix_lut<Torus> *lut,
    uint32_t shift) {
  cudaSetDevice(gpu_indexes[0]);
  // apply_lookup_table_bivariate
  auto params = lut->params;
  auto pbs_type = params.pbs_type;
  auto big_lwe_dimension = params.big_lwe_dimension;
  auto small_lwe_dimension = params.small_lwe_dimension;
  auto ks_level = params.ks_level;
  auto ks_base_log = params.ks_base_log;
  auto pbs_level = params.pbs_level;
  auto pbs_base_log = params.pbs_base_log;
  auto glwe_dimension = params.glwe_dimension;
  auto polynomial_size = params.polynomial_size;
  auto grouping_factor = params.grouping_factor;
  auto message_modulus = params.message_modulus;

  // Left message is shifted
  auto lwe_array_pbs_in = lut->tmp_lwe_before_ks;
  pack_bivariate_blocks(streams, gpu_indexes, gpu_count, lwe_array_pbs_in,
                        lut->lwe_trivial_indexes, lwe_array_1, lwe_array_2,
                        lut->lwe_indexes_in, big_lwe_dimension, shift,
                        num_radix_blocks);
  check_cuda_error(cudaGetLastError());

  // Apply LUT
  cuda_keyswitch_lwe_ciphertext_vector(
      streams[0], gpu_indexes[0], lut->tmp_lwe_after_ks,
      lut->lwe_trivial_indexes, lwe_array_pbs_in, lut->lwe_trivial_indexes, ksk,
      big_lwe_dimension, small_lwe_dimension, ks_base_log, ks_level,
      num_radix_blocks);

  execute_pbs<Torus>(streams, gpu_indexes, gpu_count, lwe_array_out,
                     lut->lwe_indexes_out, lut->lut, lut->lut_indexes,
                     lut->tmp_lwe_after_ks, lut->lwe_trivial_indexes, bsk,
                     lut->buffer, glwe_dimension, small_lwe_dimension,
                     polynomial_size, pbs_base_log, pbs_level, grouping_factor,
                     num_radix_blocks, 1, 0,
                     cuda_get_max_shared_memory(gpu_indexes[0]), pbs_type);
}

// Rotates the slice in-place such that the first mid elements of the slice move
// to the end while the last array_length elements move to the front. After
// calling rotate_left, the element previously at index mid will become the
// first element in the slice.
template <typename Torus>
void rotate_left(Torus *buffer, int mid, uint32_t array_length) {
  mid = mid % array_length;

  std::rotate(buffer, buffer + mid, buffer + array_length);
}

template <typename Torus>
void generate_lookup_table(Torus *acc, uint32_t glwe_dimension,
                           uint32_t polynomial_size, uint32_t message_modulus,
                           uint32_t carry_modulus,
                           std::function<Torus(Torus)> f) {

  uint32_t modulus_sup = message_modulus * carry_modulus;
  uint32_t box_size = polynomial_size / modulus_sup;
  Torus delta = (1ul << 63) / modulus_sup;

  memset(acc, 0, glwe_dimension * polynomial_size * sizeof(Torus));

  auto body = &acc[glwe_dimension * polynomial_size];

  // This accumulator extracts the carry bits
  for (int i = 0; i < modulus_sup; i++) {
    int index = i * box_size;
    for (int j = index; j < index + box_size; j++) {
      auto f_eval = f(i);
      body[j] = f_eval * delta;
    }
  }

  int half_box_size = box_size / 2;

  // Negate the first half_box_size coefficients
  for (int i = 0; i < half_box_size; i++) {
    body[i] = -body[i];
  }

  rotate_left(body, half_box_size, polynomial_size);
}

template <typename Torus>
void generate_lookup_table_bivariate(Torus *acc, uint32_t glwe_dimension,
                                     uint32_t polynomial_size,
                                     uint32_t message_modulus,
                                     uint32_t carry_modulus,
                                     std::function<Torus(Torus, Torus)> f) {

  Torus factor_u64 = message_modulus;
  auto wrapped_f = [factor_u64, message_modulus, f](Torus input) -> Torus {
    Torus lhs = (input / factor_u64) % message_modulus;
    Torus rhs = (input % factor_u64) % message_modulus;

    return f(lhs, rhs);
  };

  generate_lookup_table<Torus>(acc, glwe_dimension, polynomial_size,
                               message_modulus, carry_modulus, wrapped_f);
}

template <typename Torus>
void generate_lookup_table_bivariate_with_factor(
    Torus *acc, uint32_t glwe_dimension, uint32_t polynomial_size,
    uint32_t message_modulus, uint32_t carry_modulus,
    std::function<Torus(Torus, Torus)> f, int factor) {

  Torus factor_u64 = factor;
  auto wrapped_f = [factor_u64, message_modulus, f](Torus input) -> Torus {
    Torus lhs = (input / factor_u64) % message_modulus;
    Torus rhs = (input % factor_u64) % message_modulus;

    return f(lhs, rhs);
  };

  generate_lookup_table<Torus>(acc, glwe_dimension, polynomial_size,
                               message_modulus, carry_modulus, wrapped_f);
}

/*
 *  generate bivariate accumulator for device pointer
 *    stream - cuda stream
 *    acc - device pointer for bivariate accumulator
 *    ...
 *    f - wrapping function with two Torus inputs
 */
template <typename Torus>
void generate_device_accumulator_bivariate(
    cudaStream_t stream, uint32_t gpu_index, Torus *acc_bivariate,
    uint32_t glwe_dimension, uint32_t polynomial_size, uint32_t message_modulus,
    uint32_t carry_modulus, std::function<Torus(Torus, Torus)> f) {

  cudaSetDevice(gpu_index);
  // host lut
  Torus *h_lut =
      (Torus *)malloc((glwe_dimension + 1) * polynomial_size * sizeof(Torus));

  // fill bivariate accumulator
  generate_lookup_table_bivariate<Torus>(h_lut, glwe_dimension, polynomial_size,
                                         message_modulus, carry_modulus, f);

  // copy host lut and lut_indexes to device
  cuda_memcpy_async_to_gpu(acc_bivariate, h_lut,
                           (glwe_dimension + 1) * polynomial_size *
                               sizeof(Torus),
                           stream, gpu_index);

  // Release memory when possible
  cuda_stream_add_callback(stream, gpu_index, host_free_on_stream_callback,
                           h_lut);
}

/*
 *  generate bivariate accumulator with factor scaling for device pointer
 *    v_stream - cuda stream
 *    acc - device pointer for bivariate accumulator
 *    ...
 *    f - wrapping function with two Torus inputs
 */
template <typename Torus>
void generate_device_accumulator_bivariate_with_factor(
    cudaStream_t stream, uint32_t gpu_index, Torus *acc_bivariate,
    uint32_t glwe_dimension, uint32_t polynomial_size, uint32_t message_modulus,
    uint32_t carry_modulus, std::function<Torus(Torus, Torus)> f, int factor) {

  cudaSetDevice(gpu_index);
  // host lut
  Torus *h_lut =
      (Torus *)malloc((glwe_dimension + 1) * polynomial_size * sizeof(Torus));

  // fill bivariate accumulator
  generate_lookup_table_bivariate_with_factor<Torus>(
      h_lut, glwe_dimension, polynomial_size, message_modulus, carry_modulus, f,
      factor);

  // copy host lut and lut_indexes to device
  cuda_memcpy_async_to_gpu(acc_bivariate, h_lut,
                           (glwe_dimension + 1) * polynomial_size *
                               sizeof(Torus),
                           stream, gpu_index);

  // Release memory when possible
  cuda_stream_add_callback(stream, gpu_index, host_free_on_stream_callback,
                           h_lut);
}

/*
 *  generate accumulator for device pointer
 *    v_stream - cuda stream
 *    acc - device pointer for accumulator
 *    ...
 *    f - evaluating function with one Torus input
 */
template <typename Torus>
void generate_device_accumulator(cudaStream_t stream, uint32_t gpu_index,
                                 Torus *acc, uint32_t glwe_dimension,
                                 uint32_t polynomial_size,
                                 uint32_t message_modulus,
                                 uint32_t carry_modulus,
                                 std::function<Torus(Torus)> f) {

  cudaSetDevice(gpu_index);
  // host lut
  Torus *h_lut =
      (Torus *)malloc((glwe_dimension + 1) * polynomial_size * sizeof(Torus));

  // fill accumulator
  generate_lookup_table<Torus>(h_lut, glwe_dimension, polynomial_size,
                               message_modulus, carry_modulus, f);

  // copy host lut and lut_indexes to device
  cuda_memcpy_async_to_gpu(
      acc, h_lut, (glwe_dimension + 1) * polynomial_size * sizeof(Torus),
      stream, gpu_index);

  // Release memory when possible
  cuda_stream_add_callback(stream, gpu_index, host_free_on_stream_callback,
                           h_lut);
}

template <typename Torus>
void scratch_cuda_propagate_single_carry_kb_inplace(
    cudaStream_t stream, uint32_t gpu_index,
    int_sc_prop_memory<Torus> **mem_ptr, uint32_t num_radix_blocks,
    int_radix_params params, bool allocate_gpu_memory) {

  cudaSetDevice(gpu_index);
  *mem_ptr = new int_sc_prop_memory<Torus>(
      stream, gpu_index, params, num_radix_blocks, allocate_gpu_memory);
}

template <typename Torus>
void host_propagate_single_carry(cudaStream_t *streams, uint32_t *gpu_indexes,
                                 uint32_t gpu_count, Torus *lwe_array,
                                 int_sc_prop_memory<Torus> *mem, void *bsk,
                                 Torus *ksk, uint32_t num_blocks) {
  auto params = mem->params;
  auto glwe_dimension = params.glwe_dimension;
  auto polynomial_size = params.polynomial_size;
  auto big_lwe_size = glwe_dimension * polynomial_size + 1;
  auto big_lwe_size_bytes = big_lwe_size * sizeof(Torus);

  auto generates_or_propagates = mem->generates_or_propagates;
  auto step_output = mem->step_output;

  auto luts_array = mem->luts_array;
  auto luts_carry_propagation_sum = mem->luts_carry_propagation_sum;
  auto message_acc = mem->message_acc;

  integer_radix_apply_univariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, generates_or_propagates, lwe_array, bsk,
      ksk, num_blocks, luts_array);

  // compute prefix sum with hillis&steele

  int num_steps = ceil(log2((double)num_blocks));
  int space = 1;
  cudaSetDevice(gpu_indexes[0]);
  cuda_memcpy_async_gpu_to_gpu(step_output, generates_or_propagates,
                               big_lwe_size_bytes * num_blocks, streams[0],
                               gpu_indexes[0]);

  for (int step = 0; step < num_steps; step++) {
    auto cur_blocks = &step_output[space * big_lwe_size];
    auto prev_blocks = generates_or_propagates;
    int cur_total_blocks = num_blocks - space;

    integer_radix_apply_bivariate_lookup_table_kb<Torus>(
        streams, gpu_indexes, gpu_count, cur_blocks, cur_blocks, prev_blocks,
        bsk, ksk, cur_total_blocks, luts_carry_propagation_sum,
        luts_carry_propagation_sum->params.message_modulus);

    cudaSetDevice(gpu_indexes[0]);
    cuda_memcpy_async_gpu_to_gpu(
        &generates_or_propagates[space * big_lwe_size], cur_blocks,
        big_lwe_size_bytes * cur_total_blocks, streams[0], gpu_indexes[0]);
    space *= 2;
  }

  cudaSetDevice(gpu_indexes[0]);
  host_radix_blocks_rotate_right(streams, gpu_indexes, gpu_count, step_output,
                                 generates_or_propagates, 1, num_blocks,
                                 big_lwe_size);
  cuda_memset_async(step_output, 0, big_lwe_size_bytes, streams[0],
                    gpu_indexes[0]);

  host_addition(streams[0], gpu_indexes[0], lwe_array, lwe_array, step_output,
                glwe_dimension * polynomial_size, num_blocks);

  integer_radix_apply_univariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, lwe_array, lwe_array, bsk, ksk,
      num_blocks, message_acc);
}

template <typename Torus>
void host_propagate_single_sub_borrow(cudaStream_t *streams,
                                      uint32_t *gpu_indexes, uint32_t gpu_count,
                                      Torus *overflowed, Torus *lwe_array,
                                      int_single_borrow_prop_memory<Torus> *mem,
                                      void *bsk, Torus *ksk,
                                      uint32_t num_blocks) {
  cudaSetDevice(gpu_indexes[0]);
  auto params = mem->params;
  auto glwe_dimension = params.glwe_dimension;
  auto polynomial_size = params.polynomial_size;
  auto big_lwe_size = glwe_dimension * polynomial_size + 1;
  auto big_lwe_size_bytes = big_lwe_size * sizeof(Torus);

  auto generates_or_propagates = mem->generates_or_propagates;
  auto step_output = mem->step_output;

  auto luts_array = mem->luts_array;
  auto luts_carry_propagation_sum = mem->luts_borrow_propagation_sum;
  auto message_acc = mem->message_acc;

  integer_radix_apply_univariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, generates_or_propagates, lwe_array, bsk,
      ksk, num_blocks, luts_array);

  // compute prefix sum with hillis&steele
  int num_steps = ceil(log2((double)num_blocks));
  int space = 1;
  cuda_memcpy_async_gpu_to_gpu(step_output, generates_or_propagates,
                               big_lwe_size_bytes * num_blocks, streams[0],
                               gpu_indexes[0]);

  for (int step = 0; step < num_steps; step++) {
    auto cur_blocks = &step_output[space * big_lwe_size];
    auto prev_blocks = generates_or_propagates;
    int cur_total_blocks = num_blocks - space;

    integer_radix_apply_bivariate_lookup_table_kb<Torus>(
        streams, gpu_indexes, gpu_count, cur_blocks, cur_blocks, prev_blocks,
        bsk, ksk, cur_total_blocks, luts_carry_propagation_sum,
        luts_carry_propagation_sum->params.message_modulus);

    cuda_memcpy_async_gpu_to_gpu(
        &generates_or_propagates[space * big_lwe_size], cur_blocks,
        big_lwe_size_bytes * cur_total_blocks, streams[0], gpu_indexes[0]);
    space *= 2;
  }

  cuda_memcpy_async_gpu_to_gpu(
      overflowed, &generates_or_propagates[big_lwe_size * (num_blocks - 1)],
      big_lwe_size_bytes, streams[0], gpu_indexes[0]);

  host_radix_blocks_rotate_right(streams, gpu_indexes, gpu_count, step_output,
                                 generates_or_propagates, 1, num_blocks,
                                 big_lwe_size);
  cuda_memset_async(step_output, 0, big_lwe_size_bytes, streams[0],
                    gpu_indexes[0]);

  host_subtraction(streams[0], gpu_indexes[0], lwe_array, lwe_array,
                   step_output, glwe_dimension * polynomial_size, num_blocks);

  integer_radix_apply_univariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, lwe_array, lwe_array, bsk, ksk,
      num_blocks, message_acc);
}

/*
 * input_blocks: input radix ciphertext propagation will happen inplace
 * acc_message_carry: list of two lut s, [(message_acc), (carry_acc)]
 * lut_indexes_message_carry: lut_indexes for message and carry, should always
 * be  {0, 1} small_lwe_vector: output of keyswitch should have size = 2 *
 * (lwe_dimension + 1) * sizeof(Torus) big_lwe_vector: output of pbs should have
 *     size = 2 * (glwe_dimension * polynomial_size + 1) * sizeof(Torus)
 */
template <typename Torus, typename STorus, class params>
void host_full_propagate_inplace(cudaStream_t *streams, uint32_t *gpu_indexes,
                                 uint32_t gpu_count, Torus *input_blocks,
                                 int_fullprop_buffer<Torus> *mem_ptr,
                                 Torus *ksk, void *bsk, uint32_t lwe_dimension,
                                 uint32_t glwe_dimension,
                                 uint32_t polynomial_size, uint32_t ks_base_log,
                                 uint32_t ks_level, uint32_t pbs_base_log,
                                 uint32_t pbs_level, uint32_t grouping_factor,
                                 uint32_t num_blocks) {

  cudaSetDevice(gpu_indexes[0]);
  int big_lwe_size = (glwe_dimension * polynomial_size + 1);
  int small_lwe_size = (lwe_dimension + 1);

  for (int i = 0; i < num_blocks; i++) {
    auto cur_input_block = &input_blocks[i * big_lwe_size];

    cuda_keyswitch_lwe_ciphertext_vector<Torus>(
        streams[0], gpu_indexes[0], mem_ptr->tmp_small_lwe_vector,
        mem_ptr->lwe_indexes, cur_input_block, mem_ptr->lwe_indexes, ksk,
        polynomial_size * glwe_dimension, lwe_dimension, ks_base_log, ks_level,
        1);

    cuda_memcpy_async_gpu_to_gpu(&mem_ptr->tmp_small_lwe_vector[small_lwe_size],
                                 mem_ptr->tmp_small_lwe_vector,
                                 small_lwe_size * sizeof(Torus), streams[0],
                                 gpu_indexes[0]);

    execute_pbs<Torus>(
        streams, gpu_indexes, 1, mem_ptr->tmp_big_lwe_vector,
        mem_ptr->lwe_indexes, mem_ptr->lut_buffer, mem_ptr->lut_indexes,
        mem_ptr->tmp_small_lwe_vector, mem_ptr->lwe_indexes, bsk,
        mem_ptr->pbs_buffer, glwe_dimension, lwe_dimension, polynomial_size,
        pbs_base_log, pbs_level, grouping_factor, 2, 2, 0,
        cuda_get_max_shared_memory(gpu_indexes[0]), mem_ptr->pbs_type);

    cuda_memcpy_async_gpu_to_gpu(cur_input_block, mem_ptr->tmp_big_lwe_vector,
                                 big_lwe_size * sizeof(Torus), streams[0],
                                 gpu_indexes[0]);

    if (i < num_blocks - 1) {
      auto next_input_block = &input_blocks[(i + 1) * big_lwe_size];
      host_addition(streams[0], gpu_indexes[0], next_input_block,
                    next_input_block,
                    &mem_ptr->tmp_big_lwe_vector[big_lwe_size],
                    glwe_dimension * polynomial_size, 1);
    }
  }
}

template <typename Torus>
void scratch_cuda_full_propagation(
    cudaStream_t stream, uint32_t gpu_index,
    int_fullprop_buffer<Torus> **mem_ptr, uint32_t lwe_dimension,
    uint32_t glwe_dimension, uint32_t polynomial_size, uint32_t pbs_level,
    uint32_t grouping_factor, uint32_t num_radix_blocks,
    uint32_t message_modulus, uint32_t carry_modulus, PBS_TYPE pbs_type,
    bool allocate_gpu_memory) {

  int8_t *pbs_buffer;
  execute_scratch_pbs<Torus>(
      stream, gpu_index, &pbs_buffer, glwe_dimension, lwe_dimension,
      polynomial_size, pbs_level, grouping_factor, num_radix_blocks,
      cuda_get_max_shared_memory(gpu_index), pbs_type, allocate_gpu_memory);

  // LUT
  Torus *lut_buffer;
  if (allocate_gpu_memory) {
    // LUT is used as a trivial encryption, so we only allocate memory for the
    // body
    Torus lut_buffer_size =
        2 * (glwe_dimension + 1) * polynomial_size * sizeof(Torus);

    lut_buffer = (Torus *)cuda_malloc_async(lut_buffer_size, stream, gpu_index);

    // LUTs
    auto lut_f_message = [message_modulus](Torus x) -> Torus {
      return x % message_modulus;
    };
    auto lut_f_carry = [message_modulus](Torus x) -> Torus {
      return x / message_modulus;
    };

    //
    Torus *lut_buffer_message = lut_buffer;
    Torus *lut_buffer_carry =
        lut_buffer + (glwe_dimension + 1) * polynomial_size;

    generate_device_accumulator<Torus>(
        stream, gpu_index, lut_buffer_message, glwe_dimension, polynomial_size,
        message_modulus, carry_modulus, lut_f_message);

    generate_device_accumulator<Torus>(
        stream, gpu_index, lut_buffer_carry, glwe_dimension, polynomial_size,
        message_modulus, carry_modulus, lut_f_carry);
  }

  Torus *lut_indexes;
  if (allocate_gpu_memory) {
    lut_indexes =
        (Torus *)cuda_malloc_async(2 * sizeof(Torus), stream, gpu_index);

    Torus h_lut_indexes[2] = {0, 1};
    cuda_memcpy_async_to_gpu(lut_indexes, h_lut_indexes, 2 * sizeof(Torus),
                             stream, gpu_index);
  }

  Torus *lwe_indexes;
  if (allocate_gpu_memory) {
    Torus lwe_indexes_size = num_radix_blocks * sizeof(Torus);

    lwe_indexes =
        (Torus *)cuda_malloc_async(lwe_indexes_size, stream, gpu_index);
    Torus *h_lwe_indexes = (Torus *)malloc(lwe_indexes_size);
    for (int i = 0; i < num_radix_blocks; i++)
      h_lwe_indexes[i] = i;
    cuda_memcpy_async_to_gpu(lwe_indexes, h_lwe_indexes, lwe_indexes_size,
                             stream, gpu_index);
    cuda_stream_add_callback(stream, gpu_index, host_free_on_stream_callback,
                             h_lwe_indexes);
  }

  // Temporary arrays
  Torus *small_lwe_vector;
  Torus *big_lwe_vector;
  if (allocate_gpu_memory) {
    Torus small_vector_size = 2 * (lwe_dimension + 1) * sizeof(Torus);
    Torus big_vector_size =
        2 * (glwe_dimension * polynomial_size + 1) * sizeof(Torus);

    small_lwe_vector =
        (Torus *)cuda_malloc_async(small_vector_size, stream, gpu_index);
    big_lwe_vector =
        (Torus *)cuda_malloc_async(big_vector_size, stream, gpu_index);
  }

  *mem_ptr = new int_fullprop_buffer<Torus>;

  (*mem_ptr)->pbs_type = pbs_type;
  (*mem_ptr)->pbs_buffer = pbs_buffer;

  (*mem_ptr)->lut_buffer = lut_buffer;
  (*mem_ptr)->lut_indexes = lut_indexes;
  (*mem_ptr)->lwe_indexes = lwe_indexes;

  (*mem_ptr)->tmp_small_lwe_vector = small_lwe_vector;
  (*mem_ptr)->tmp_big_lwe_vector = big_lwe_vector;
}

// (lwe_dimension+1) threads
// (num_radix_blocks / 2) thread blocks
template <typename Torus>
__global__ void device_pack_blocks(Torus *lwe_array_out, Torus *lwe_array_in,
                                   uint32_t lwe_dimension,
                                   uint32_t num_radix_blocks, uint32_t factor) {
  int tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid < (lwe_dimension + 1)) {
    for (int bid = 0; bid < (num_radix_blocks / 2); bid++) {
      Torus *lsb_block = lwe_array_in + (2 * bid) * (lwe_dimension + 1);
      Torus *msb_block = lsb_block + (lwe_dimension + 1);

      Torus *packed_block = lwe_array_out + bid * (lwe_dimension + 1);

      packed_block[tid] = lsb_block[tid] + factor * msb_block[tid];
    }

    if (num_radix_blocks % 2 == 1) {
      // We couldn't pack the last block, so we just copy it
      Torus *lsb_block =
          lwe_array_in + (num_radix_blocks - 1) * (lwe_dimension + 1);
      Torus *last_block =
          lwe_array_out + (num_radix_blocks / 2) * (lwe_dimension + 1);

      last_block[tid] = lsb_block[tid];
    }
  }
}

// Packs the low ciphertext in the message parts of the high ciphertext
// and moves the high ciphertext into the carry part.
//
// This requires the block parameters to have enough room for two ciphertexts,
// so at least as many carry modulus as the message modulus
//
// Expects the carry buffer to be empty
template <typename Torus>
__host__ void pack_blocks(cudaStream_t stream, uint32_t gpu_index,
                          Torus *lwe_array_out, Torus *lwe_array_in,
                          uint32_t lwe_dimension, uint32_t num_radix_blocks,
                          uint32_t factor) {
  cudaSetDevice(gpu_index);

  int num_blocks = 0, num_threads = 0;
  int num_entries = (lwe_dimension + 1);
  getNumBlocksAndThreads(num_entries, 512, num_blocks, num_threads);
  device_pack_blocks<<<num_blocks, num_threads, 0, stream>>>(
      lwe_array_out, lwe_array_in, lwe_dimension, num_radix_blocks, factor);
}

template <typename Torus>
__global__ void
device_create_trivial_radix(Torus *lwe_array, Torus *scalar_input,
                            int32_t num_blocks, uint32_t lwe_dimension,
                            uint64_t delta) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid < num_blocks) {
    Torus scalar = scalar_input[tid];
    Torus *body = lwe_array + tid * (lwe_dimension + 1) + lwe_dimension;

    *body = scalar * delta;
  }
}

template <typename Torus>
__host__ void
create_trivial_radix(cudaStream_t stream, uint32_t gpu_index,
                     Torus *lwe_array_out, Torus *scalar_array,
                     uint32_t lwe_dimension, uint32_t num_radix_blocks,
                     uint32_t num_scalar_blocks, uint64_t message_modulus,
                     uint64_t carry_modulus) {

  cudaSetDevice(gpu_index);
  size_t radix_size = (lwe_dimension + 1) * num_radix_blocks;
  cuda_memset_async(lwe_array_out, 0, radix_size * sizeof(Torus), stream,
                    gpu_index);

  if (num_scalar_blocks == 0)
    return;

  // Create a 1-dimensional grid of threads
  int num_blocks = 0, num_threads = 0;
  int num_entries = num_scalar_blocks;
  getNumBlocksAndThreads(num_entries, 512, num_blocks, num_threads);
  dim3 grid(num_blocks, 1, 1);
  dim3 thds(num_threads, 1, 1);

  // Value of the shift we multiply our messages by
  // If message_modulus and carry_modulus are always powers of 2 we can simplify
  // this
  uint64_t delta = ((uint64_t)1 << 63) / (message_modulus * carry_modulus);

  device_create_trivial_radix<<<grid, thds, 0, stream>>>(
      lwe_array_out, scalar_array, num_scalar_blocks, lwe_dimension, delta);
  check_cuda_error(cudaGetLastError());
}

/**
 * Each bit in lwe_array_in becomes a lwe ciphertext in lwe_array_out
 * Thus, lwe_array_out must be allocated with num_radix_blocks * bits_per_block
 * * (lwe_dimension+1) * sizeeof(Torus) bytes
 */
template <typename Torus>
__host__ void extract_n_bits(cudaStream_t *streams, uint32_t *gpu_indexes,
                             uint32_t gpu_count, Torus *lwe_array_out,
                             Torus *lwe_array_in, void *bsk, Torus *ksk,
                             uint32_t num_radix_blocks, uint32_t bits_per_block,
                             int_bit_extract_luts_buffer<Torus> *bit_extract) {

  integer_radix_apply_univariate_lookup_table_kb(
      streams, gpu_indexes, gpu_count, lwe_array_out, lwe_array_in, bsk, ksk,
      num_radix_blocks * bits_per_block, bit_extract->lut);
}

template <typename Torus>
__host__ void reduce_signs(cudaStream_t *streams, uint32_t *gpu_indexes,
                           uint32_t gpu_count, Torus *signs_array_out,
                           Torus *signs_array_in,
                           int_comparison_buffer<Torus> *mem_ptr,
                           std::function<Torus(Torus)> sign_handler_f,
                           void *bsk, Torus *ksk, uint32_t num_sign_blocks) {

  cudaSetDevice(gpu_indexes[0]);
  auto diff_buffer = mem_ptr->diff_buffer;

  auto params = mem_ptr->params;
  auto big_lwe_dimension = params.big_lwe_dimension;
  auto glwe_dimension = params.glwe_dimension;
  auto polynomial_size = params.polynomial_size;
  auto message_modulus = params.message_modulus;
  auto carry_modulus = params.carry_modulus;

  std::function<Torus(Torus)> reduce_two_orderings_function =
      [diff_buffer, sign_handler_f](Torus x) -> Torus {
    int msb = (x >> 2) & 3;
    int lsb = x & 3;

    return diff_buffer->tree_buffer->block_selector_f(msb, lsb);
  };

  auto signs_a = diff_buffer->tmp_signs_a;
  auto signs_b = diff_buffer->tmp_signs_b;

  cuda_memcpy_async_gpu_to_gpu(signs_a, signs_array_in,
                               (big_lwe_dimension + 1) * num_sign_blocks *
                                   sizeof(Torus),
                               streams[0], gpu_indexes[0]);
  if (num_sign_blocks > 2) {
    auto lut = diff_buffer->reduce_signs_lut;
    generate_device_accumulator<Torus>(
        streams[0], gpu_indexes[0], lut->lut, glwe_dimension, polynomial_size,
        message_modulus, carry_modulus, reduce_two_orderings_function);

    while (num_sign_blocks > 2) {
      pack_blocks(streams[0], gpu_indexes[0], signs_b, signs_a,
                  big_lwe_dimension, num_sign_blocks, 4);
      integer_radix_apply_univariate_lookup_table_kb(
          streams, gpu_indexes, gpu_count, signs_a, signs_b, bsk, ksk,
          num_sign_blocks / 2, lut);

      auto last_block_signs_b =
          signs_b + (num_sign_blocks / 2) * (big_lwe_dimension + 1);
      auto last_block_signs_a =
          signs_a + (num_sign_blocks / 2) * (big_lwe_dimension + 1);
      if (num_sign_blocks % 2 == 1)
        cuda_memcpy_async_gpu_to_gpu(last_block_signs_a, last_block_signs_b,
                                     (big_lwe_dimension + 1) * sizeof(Torus),
                                     streams[0], gpu_indexes[0]);

      num_sign_blocks = (num_sign_blocks / 2) + (num_sign_blocks % 2);
    }
  }

  if (num_sign_blocks == 2) {
    std::function<Torus(Torus)> final_lut_f =
        [reduce_two_orderings_function, sign_handler_f](Torus x) -> Torus {
      Torus final_sign = reduce_two_orderings_function(x);
      return sign_handler_f(final_sign);
    };

    auto lut = diff_buffer->reduce_signs_lut;
    generate_device_accumulator<Torus>(
        streams[0], gpu_indexes[0], lut->lut, glwe_dimension, polynomial_size,
        message_modulus, carry_modulus, final_lut_f);

    pack_blocks(streams[0], gpu_indexes[0], signs_b, signs_a, big_lwe_dimension,
                2, 4);
    integer_radix_apply_univariate_lookup_table_kb(streams, gpu_indexes,
                                                   gpu_count, signs_array_out,
                                                   signs_b, bsk, ksk, 1, lut);

  } else {

    std::function<Torus(Torus)> final_lut_f =
        [mem_ptr, sign_handler_f](Torus x) -> Torus {
      return sign_handler_f(x & 3);
    };

    auto lut = mem_ptr->diff_buffer->reduce_signs_lut;
    generate_device_accumulator<Torus>(
        streams[0], gpu_indexes[0], lut->lut, glwe_dimension, polynomial_size,
        message_modulus, carry_modulus, final_lut_f);

    integer_radix_apply_univariate_lookup_table_kb(streams, gpu_indexes,
                                                   gpu_count, signs_array_out,
                                                   signs_a, bsk, ksk, 1, lut);
  }
}

template <typename Torus>
void scratch_cuda_apply_univariate_lut_kb(
    cudaStream_t stream, uint32_t gpu_index, int_radix_lut<Torus> **mem_ptr,
    Torus *input_lut, uint32_t num_radix_blocks, int_radix_params params,
    bool allocate_gpu_memory) {

  *mem_ptr = new int_radix_lut<Torus>(stream, gpu_index, params, 1,
                                      num_radix_blocks, allocate_gpu_memory);
  cuda_memcpy_async_to_gpu((*mem_ptr)->lut, input_lut,
                           (params.glwe_dimension + 1) *
                               params.polynomial_size * sizeof(Torus),
                           stream, gpu_index);
}

template <typename Torus>
void host_apply_univariate_lut_kb(cudaStream_t *streams, uint32_t *gpu_indexes,
                                  uint32_t gpu_count, Torus *radix_lwe_out,
                                  Torus *radix_lwe_in,
                                  int_radix_lut<Torus> *mem, Torus *ksk,
                                  void *bsk, uint32_t num_blocks) {

  cudaSetDevice(gpu_indexes[0]);
  integer_radix_apply_univariate_lookup_table_kb<Torus>(
      streams, gpu_indexes, gpu_count, radix_lwe_out, radix_lwe_in, bsk, ksk,
      num_blocks, mem);
}

#endif // TFHE_RS_INTERNAL_INTEGER_CUH

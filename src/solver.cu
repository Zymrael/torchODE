#include <torch/extension.h>

#include <iostream>
#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>
#include <map>

typedef void (*solver_t)(torch::PackedTensorAccessor<float, 2>, torch::PackedTensorAccessor<float, 1>, torch::PackedTensorAccessor<float, 1>, float, int, int);
typedef float (*method_t)(float, float, float, float);
typedef std::string string;

__device__ float
euler_method(float F_in, float x0_in, float g_in, float dt) {
	return (F_in * g_in) * dt;
}

__device__ float
rk4_method(float F_in, float x0_in, float g_in, float dt) {
	auto f1 = (F_in * g_in)*dt;

	auto c2 = dt * f1 / 2.0;
        auto f2 = (F_in * (g_in + c2)) * (dt / 2.0);

	auto c3 = dt * f2 / 2.0;
        auto f3 = (F_in * (g_in + c3)) * (dt / 2.0);

	auto c4 = dt * f3;
	auto f4 = (F_in * (g_in + c4)) * dt;

	return (f1 + 2.0 * f2 + 2.0 * f3 + f4) / 6.0;
}


__global__ void
general_solver(method_t method, torch::PackedTensorAccessor<float, 2> F_a, torch::PackedTensorAccessor<float, 1> x0_a, torch::PackedTensorAccessor<float, 1> g_a, float dt, int steps, int x0_size) { 
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size){
        auto x0_in = x0_a[tid];
	auto g_in = g_a[tid];
        auto F_in = F_a[tid][tid];

   	for(int i = 0; i < steps; i++) {
		x0_in = x0_in + method(F_in, x0_in, g_in, dt);
	}

        x0_a[tid] = x0_in;
    }
}

__global__ void
compact_diagonal_solver(method_t method, torch::PackedTensorAccessor<float, 2> F_a, torch::PackedTensorAccessor<float, 1> x0_a, torch::PackedTensorAccessor<float, 1> g_a, float dt, int steps, int x0_size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size){
        auto x0_in = x0_a[tid];
	auto g_in = g_a[tid];
	auto F_in = F_a[0][0];

   	for(int i = 0; i < steps; i++) {
		x0_in = x0_in + method(F_in, x0_in, g_in, dt);
	}

        x0_a[tid] = x0_in;
    }
}

__global__ void
general_skew_symmetric_solver(method_t method, torch::PackedTensorAccessor<float, 2> F_a, torch::PackedTensorAccessor<float, 1> x0_a, torch::PackedTensorAccessor<float, 1> g_a, float dt, int steps, int x0_size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size/2) {
	auto g_in_1 = g_a[tid];
	auto g_in_2 = g_a[tid + x0_size/2];

        auto x0_in_1 = x0_a[tid];
        auto x0_in_2 = x0_a[tid + x0_size/2];

	auto UL_v = F_a[tid][tid];
	auto UR_v = F_a[tid][tid + x0_size/2];
	auto LL_v = F_a[tid + x0_size/2][tid];
	auto LR_v = F_a[tid + x0_size/2][tid + x0_size/2];

   	for(int i = 0; i < steps; i++) {
		x0_in_1 = x0_in_1 + method(UL_v, x0_in_1, g_in_1, dt)
				  + method(UR_v, x0_in_2, g_in_2, dt);
		x0_in_2 = x0_in_1 + method(LL_v, x0_in_1, g_in_1, dt)
				  + method(LR_v, x0_in_2, g_in_2, dt);
	}

        x0_a[tid] = x0_in_1;
	x0_a[tid + x0_size/2] = x0_in_2;
    }
}

__global__ void
compact_skew_symmetric_solver(method_t method, torch::PackedTensorAccessor<float, 2> F_a, torch::PackedTensorAccessor<float, 1> x0_a, torch::PackedTensorAccessor<float, 1> g_a, float dt, int steps, int x0_size) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if(tid < x0_size/2) {
	auto g_in_1 = g_a[tid];
	auto g_in_2 = g_a[tid + x0_size/2];

        auto x0_in_1 = x0_a[tid];
        auto x0_in_2 = x0_a[tid + x0_size/2];

	auto UL_v = F_a[0][0];
	auto UR_v = F_a[0][1];
	auto LL_v = F_a[1][0];
	auto LR_v = F_a[1][1];

   	for(int i = 0; i < steps; i++) {
		x0_in_1 = x0_in_1 + method(UL_v, x0_in_1, g_in_1, dt)
				  + method(UR_v, x0_in_2, g_in_2, dt);
		x0_in_2 = x0_in_1 + method(LL_v, x0_in_1, g_in_1, dt)
				  + method(LR_v, x0_in_2, g_in_2, dt);
	}

        x0_a[tid] = x0_in_1;
	x0_a[tid + x0_size/2] = x0_in_2;
    }
}

// Declare static pointers to device functions
__device__ method_t p_euler_method = euler_method;
__device__ method_t p_rk4_method = rk4_method;

torch::Tensor solve_cuda(torch::Tensor F, torch::Tensor x0, torch::Tensor g, float dt, int steps, string name){

    std::map<string, method_t> h_methods;
    method_t h_euler_method;
    method_t h_rk4_method; 

    // Copy device function pointers to host side
    cudaMemcpyFromSymbol(&h_euler_method, p_euler_method, sizeof(method_t));
    cudaMemcpyFromSymbol(&h_rk4_method, p_rk4_method, sizeof(method_t));

    h_methods["Euler"] = h_euler_method;
    h_methods["RK4"] = h_rk4_method;

    method_t d_chosen_method = h_methods[name];

    auto F_a = F.packed_accessor<float,2>();
    auto x0_a = x0.packed_accessor<float,1>();
    auto g_a = g.packed_accessor<float,1>();

    auto F_size = torch::size(F, 0);
    auto x0_size = torch::size(x0, 0);

    const int threadsPerBlock = 512; 
    const int blocks = (x0_size + threadsPerBlock - 1) / threadsPerBlock;

    switch(F_size) {
	case 1:
		compact_diagonal_solver<<<blocks, threadsPerBlock>>>(d_chosen_method, F_a, x0_a, g_a, dt, steps, x0_size);
		break;
	case 2:
		compact_skew_symmetric_solver<<<blocks, threadsPerBlock>>>(d_chosen_method, F_a, x0_a, g_a, dt, steps, x0_size);
		break;
	default:
		general_skew_symmetric_solver<<<blocks, threadsPerBlock>>>(d_chosen_method, F_a, x0_a, g_a, dt, steps, x0_size);
		break;
    }
    
    return x0;
}


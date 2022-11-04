/* Copyright 2022. Uecker Lab. University Medical Center Göttingen.
 * All rights reserved. Use of this source code is governed by
 * a BSD-style license which can be found in the LICENSE file.
 *
 * Authors: Moritz Blumenthal
 */

#include <cuda_runtime_api.h>
#include <cuda.h>
#include <cuComplex.h>

#include <assert.h>
#include <stdbool.h>

#include "misc/misc.h"

#include "num/multind.h"
#include "num/gpu_misc.h"
#include "num/gpuops.h"

#include "noncart/grid.h"
#include "gpu_grid.h"

__device__ cuFloatComplex zexp(cuFloatComplex x)
{
	float sc = expf(cuCrealf(x));
	float si;
	float co;
	sincosf(cuCimagf(x), &si, &co);
	return make_cuFloatComplex(sc * co, sc * si);
}

struct linphase_conf {

	long dims[3];
	long tot;
	float shifts[3];
	long N;
	float cn;
	float scale;
	_Bool conj;
	_Bool fmac;
};

__global__ void kern_apply_linphases_3D(struct linphase_conf c, cuFloatComplex* dst, const cuFloatComplex* src)
{
	int startX = threadIdx.x + blockDim.x * blockIdx.x;
	int strideX = blockDim.x * gridDim.x;

	int startY = threadIdx.y + blockDim.y * blockIdx.y;
	int strideY = blockDim.y * gridDim.y;

	int startZ = threadIdx.z + blockDim.z * blockIdx.z;
	int strideZ = blockDim.z * gridDim.z;

	for (long z = startZ; z < c.dims[2]; z += strideZ)
		for (long y = startY; y < c.dims[1]; y += strideY)
			for (long x = startX; x < c.dims[0]; x +=strideX) {

				long pos[3] = { x, y, z };
				long idx = x + c.dims[0] * (y + c.dims[1] * z);
				
				float val = c.cn;

				for (int n = 0; n < 3; n++)
					val += pos[n] * c.shifts[n];

				if (c.conj)
					val = -val;
				
				cuFloatComplex cval = make_cuFloatComplex(0, val);
				cval = zexp(cval);

				cval.x *= c.scale;
				cval.y *= c.scale;

				if (c.fmac) {

					for (long i = 0; i < c.N; i++)
						dst[idx + i * c.tot] = cuCaddf(dst[idx + i * c.tot], cuCmulf(src[idx + i * c.tot], cval));
				} else {

					for (long i = 0; i < c.N; i++)
						dst[idx + i * c.tot] = cuCmulf(src[idx + i * c.tot], cval);
				}
			}
}



extern "C" void cuda_apply_linphases_3D(int N, const long img_dims[], const float shifts[3], _Complex float* dst, const _Complex float* src, _Bool conj, _Bool fmac, float scale)
{
	struct linphase_conf c;

	c.cn = 0;
	c.tot = 1;
	c.N = 1;
	c.scale = scale;
	c.conj = conj;
	c.fmac = fmac;

	for (int n = 0; n < 3; n++) {

		c.shifts[n] = 2. * M_PI * (float)(shifts[n]) / ((float)img_dims[n]);
		c.cn -= c.shifts[n] * (float)img_dims[n] / 2.;
		
		c.dims[n] = img_dims[n];
		c.tot *= c.dims[n];
	}

	c.N = md_calc_size(N - 3, img_dims + 3);

	const void* func = (const void*)kern_apply_linphases_3D;
	kern_apply_linphases_3D<<<getGridSize3(c.dims, func), getBlockSize3(c.dims, (const void*)func), 0, cuda_get_stream()>>>(c, (cuFloatComplex*)dst, (const cuFloatComplex*)src);
}


static __device__ double ftkb(double beta, double x)
{
	double a = sqrt(pow(beta, 2.) - pow(M_PI * x, 2.));
	return ((0. == a) ? 1. : (a / sinh(a))); // * bessel_i0(beta);
}

static __device__ double rolloff(double x, double beta, double width)
{
	return ftkb(beta, x * width) / ftkb(beta, 0.);
}

static __device__ float posf(int d, int i)
{
	return (1 == d) ? 0. : (((float)i - (float)d / 2.) / (float)d);
}

struct rolloff_conf {

	long dims[3];
	long tot;
	long N;
	float os;
	float width;
	float beta;
};

__global__ void kern_apply_rolloff_correction(struct rolloff_conf c, cuFloatComplex* dst, const cuFloatComplex* src)
{
	int startX = threadIdx.x + blockDim.x * blockIdx.x;
	int strideX = blockDim.x * gridDim.x;

	int startY = threadIdx.y + blockDim.y * blockIdx.y;
	int strideY = blockDim.y * gridDim.y;

	int startZ = threadIdx.z + blockDim.z * blockIdx.z;
	int strideZ = blockDim.z * gridDim.z;

	for (long z = startZ; z < c.dims[2]; z += strideZ)
		for (long y = startY; y < c.dims[1]; y += strideY)
			for (long x = startX; x < c.dims[0]; x +=strideX) {

				long idx = x + c.dims[0] * (y + c.dims[1] * z);
				
				float val = rolloff(c.os * posf(c.dims[0], x), c.beta, c.width)
					  * rolloff(c.os * posf(c.dims[1], y), c.beta, c.width)
					  * rolloff(c.os * posf(c.dims[2], z), c.beta, c.width);

				for (long i = 0; i < c.N; i++) {

					dst[idx + i * c.tot].x = val * src[idx + i * c.tot].x;
					dst[idx + i * c.tot].y = val * src[idx + i * c.tot].y;
				}
			}
}



extern "C" void cuda_apply_rolloff_correction(float os, float width, float beta, int N, const long dims[], _Complex float* dst, const _Complex float* src)
{
	struct rolloff_conf c = {

		.dims = { dims[0], dims[1], dims[2] },
		.tot = md_calc_size(3, dims),
		.N = md_calc_size(N - 3, dims + 3),
		.os = os,
		.width = width,
		.beta = beta,
	};

	const void* func = (const void*)kern_apply_rolloff_correction;
	kern_apply_rolloff_correction<<<getGridSize3(c.dims, func), getBlockSize3(c.dims, (const void*)func), 0, cuda_get_stream()>>>(c, (cuFloatComplex*)dst, (const cuFloatComplex*)src);
}


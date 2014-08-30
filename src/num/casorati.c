/* Copyright 2013. The Regents of the University of California.
 * All rights reserved. Use of this source code is governed by 
 * a BSD-style license which can be found in the LICENSE file.
 *
 * Authors:
 * 2012 Martin Uecker uecker@eecs.berkeley.edu
 */

#include <complex.h>
#include <assert.h>

#include "num/multind.h"
#include "num/flpmath.h"

#include "casorati.h"


static void calc_casorati_geom(unsigned int N, long dimc[2 * N], long str2[2 * N], const long dimk[N], const long dim[N], const long str[N])
{
	for (unsigned int i = 0; i < N; i++) {

		dimc[i + 0] = dim[i] - dimk[i] + 1;	// number of shifted blocks
		dimc[i + N] = dimk[i];			// size of blocks

		str2[i + N] = str[i];			// by having the same strides
		str2[i + 0] = str[i];			// we can address overlapping blocks
	}
}


void casorati_matrix(unsigned int N, const long dimk[N], const long odim[2], complex float* optr, const long dim[N], const long str[N], const complex float* iptr)
{
	long str2[2 * N];
	long strc[2 * N];
	long dimc[2 * N];

	calc_casorati_geom(N, dimc, str2, dimk, dim, str);

	assert(odim[0] == md_calc_size(N, dimc));	// all shifts are collapsed
	assert(odim[1] == md_calc_size(N, dimc + N));	// linearized size of a block

	md_calc_strides(2 * N, strc, dimc, CFL_SIZE);
	md_copy2(2 * N, dimc, strc, optr, str2, iptr, CFL_SIZE);
}



void casorati_matrixH(unsigned int N, const long dimk[N], const long dim[N], const long str[N], complex float* optr, const long odim[2], const complex float* iptr)
{
	long str2[2 * N];
	long strc[2 * N];
	long dimc[2 * N];

	calc_casorati_geom(N, dimc, str2, dimk, dim, str);

	assert(odim[0] == md_calc_size(N, dimc));
	assert(odim[1] == md_calc_size(N, dimc + N));

	md_calc_strides(2 * N, strc, dimc, CFL_SIZE);
	md_zadd2(2 * N, dimc, str2, optr, str2, optr, strc, iptr);
}






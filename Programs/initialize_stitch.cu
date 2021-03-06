#define BLOCK_SIZE 8
#define BLOCK_VOLUME 8*8*8
#define META_DIM %(META_BLOCKDIM)s
#define DIM %(DIM)s
#include <pycuda-complex.hpp>
#define INDEX(k,j,i,ld) ((k)*ld*ld + (j) * ld + (i))
#define E (float) (2.7182818284)
texture<float,2> pspec;

 __global__ void HII_filter(pycuda::complex<float>* fourierbox, int w, int meta_z, int filter_type, float R)
{
  int tx = threadIdx.x;  int ty = threadIdx.y; int tz = threadIdx.z;
  int bx = blockIdx.x;   int by = blockIdx.y; int bz = blockIdx.z;
  int bdx = blockDim.x;  int bdy = blockDim.y; int bdz = blockDim.z;
  int i = bdx * bx + tx; int j = bdy * by + ty; int k = bdz * bz + tz;
  int meta_i = i;
  int meta_j = j;
  int meta_k = meta_z*META_DIM + k;
  int p = INDEX(k,j,i,w);
  if (j >= w || i >= w || k >= w) return;
  float k_x, k_y, k_z, k_mag, kR;
  int hw = DIM/2; 
  k_z = (meta_k>hw) ? (meta_k-DIM)*%(DELTAK)s : meta_k*%(DELTAK)s;
  k_y = (meta_j>hw) ? (meta_j-DIM)*%(DELTAK)s : meta_j*%(DELTAK)s;
  k_x = (meta_i>hw) ? (meta_i-DIM)*%(DELTAK)s : meta_i*%(DELTAK)s;

  k_mag = sqrt(k_x*k_x + k_y*k_y + k_z*k_z);
  kR = k_mag*R; 
  switch (filter_type) {
    case 0: // real space top-hat
      if (kR > 1e-4){
        fourierbox[p] *= 3.0 * (sin(kR)/pow(kR, float(3)) - cos(kR)/pow(kR, float(2)));
      }
    case 1: // k-space top hat
      kR *= 0.413566994; // equates integrated volume to the real space top-hat (9pi/2)^(-1/3)
      if (kR > 1){
        fourierbox[p] = 0;
      }
    case 2: // gaussian
      kR *= 0.643; // equates integrated volume to the real space top-hat
      fourierbox[p] *= pow(E, float(-kR*kR/2.0));
  }
}


__global__ void init_kernel(float* fourierbox, int w, int meta_z)
{
  int tx = threadIdx.x;  int ty = threadIdx.y; int tz = threadIdx.z;
  int bx = blockIdx.x;   int by = blockIdx.y; int bz = blockIdx.z;
  int bdx = blockDim.x;  int bdy = blockDim.y; int bdz = blockDim.z;
  int i = bdx * bx + tx; int j = bdy * by + ty; int k = bdz * bz + tz;
  int meta_i = i;
  int meta_j = j;
  int meta_k = meta_z*META_DIM + k;
  int p = INDEX(k,j,i,w); int tp = INDEX(tz,ty,tx, bdx);
  if (j >= w || i >= w || k >= w) return;
  float k_x, k_y, k_z, k_mag, ps;
  int hw = DIM/2; 
  k_z = (meta_k>hw) ? (meta_k-DIM)*%(DELTAK)s : meta_k*%(DELTAK)s;
  k_y = (meta_j>hw) ? (meta_j-DIM)*%(DELTAK)s : meta_j*%(DELTAK)s;
  k_x = (meta_i>hw) ? (meta_i-DIM)*%(DELTAK)s : meta_i*%(DELTAK)s;

  k_mag = sqrt(k_x*k_x + k_y*k_y + k_z*k_z);

  __shared__ float s_K[BLOCK_VOLUME];
  __shared__ float s_P[BLOCK_VOLUME];
  if (tp < BLOCK_VOLUME) {
    s_K[tp] = tex2D(pspec, 0, tp);
    s_P[tp] = tex2D(pspec, 1, tp);
  }
  __syncthreads();

  if (k_mag == 0)
  {
    fourierbox[p] = 0.0;
    return;
  }
  //Linear Interpolation of power spectrum
  int ind = 0;
  while (s_K[ind]< k_mag){ ind++; }
  ps = s_P[ind-1] + (s_P[ind] - s_P[ind-1])*(k_mag - s_K[ind-1])/(s_K[ind] - s_K[ind-1]);

  //fourierbox[p] = sqrt(ps * %(VOLUME)s / 2.0f);//use this one if adj_complex
  fourierbox[p] = sqrt(ps * %(VOLUME)s );
}

__global__ void subsample(float* largebox, float* smallbox, int w, int sw, float pixel_factor)
{
  int tx = threadIdx.x;  int ty = threadIdx.y; int tz = threadIdx.z;
  int bx = blockIdx.x;   int by = blockIdx.y; int bz = blockIdx.z;
  int bdx = blockDim.x;  int bdy = blockDim.y; int bdz = blockDim.z;
  int i = bdx * bx + tx; int j = bdy * by + ty; int k = bdz * bz + tz;
  int p = INDEX(k,j,i,sw);
  int lk = floor(k*pixel_factor + 0.5);
  int lj = floor(j*pixel_factor + 0.5);
  int li = floor(i*pixel_factor + 0.5);

  if (j >= sw || i >= sw || k >= sw) return;
  smallbox[p] = largebox[INDEX(lk,lj,li,w)];
}

__global__ void set_velocity(pycuda::complex<float>* fourierbox, pycuda::complex<float>* vbox, int w, int meta_z, int comp)
{
  int tx = threadIdx.x;  int ty = threadIdx.y; int tz = threadIdx.z;
  int bx = blockIdx.x;   int by = blockIdx.y; int bz = blockIdx.z;
  int bdx = blockDim.x;  int bdy = blockDim.y; int bdz = blockDim.z;
  int i = bdx * bx + tx; int j = bdy * by + ty; int k = bdz * bz + tz;
  int meta_i = i;
  int meta_j = j;
  int meta_k = meta_z*META_DIM + k;
  int p = INDEX(k,j,i,w); 
  if (j >= w || i >= w || k >= w) return;
  float k_x, k_y, k_z, k_sq;
  int hw = w/2; 
  k_z = (meta_k>hw) ? (meta_k-DIM)*%(DELTAK)s : meta_k*%(DELTAK)s;
  k_y = (meta_j>hw) ? (meta_j-DIM)*%(DELTAK)s : meta_j*%(DELTAK)s;
  k_x = (meta_i>hw) ? (meta_i-DIM)*%(DELTAK)s : meta_i*%(DELTAK)s;

  k_sq = k_x*k_x + k_y*k_y + k_z*k_z;
  if (k_sq == 0)
  {
    vbox[p] = 0.0;
    return;
  }
  pycuda::complex<float> I = pycuda::complex<float>(0.f, 1.f);
  pycuda::complex<float> factor;
  switch (comp) {
    case 0:
      factor = k_x*I/k_sq;
    case 1:
      factor = k_y*I/k_sq;
    case 2:
      factor = k_z*I/k_sq;
  vbox[p] = factor * fourierbox[p];
  }
}
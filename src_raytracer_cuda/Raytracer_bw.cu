#include "Raytracer_bw.h"
#include "Array.h"
#include <curand_kernel.h>
#include "rrtmgp_kernel_launcher_cuda.h"
#include "raytracer_kernels_bw.h"
#include "Optical_props.h"
namespace
{
    template<typename TF>__global__
    void normalize_xyz_camera_kernel(
            const int cam_nx, const int cam_ny,
            const TF total_source,
            TF* __restrict__ XYZ)
    {
        const int ix = blockIdx.x*blockDim.x + threadIdx.x;
        const int iy = blockIdx.y*blockDim.y + threadIdx.y;
        if ( ( ix < cam_nx) && ( iy < cam_ny) )
        {
            for (int i=0; i<3; ++i)
            {
                const int idx_out = ix + iy*cam_nx + i*cam_nx*cam_ny;
                XYZ[idx_out] /= total_source;
            }
        }
    }
    
    template<typename TF>__global__
    void add_xyz_camera_kernel(
            const int cam_nx, const int cam_ny,
            const TF* __restrict__ xyz_factor,
            const TF* __restrict__ flux_camera,
            TF* __restrict__ XYZ)
    {
        const int ix = blockIdx.x*blockDim.x + threadIdx.x;
        const int iy = blockIdx.y*blockDim.y + threadIdx.y;
        if ( ( ix < cam_nx) && ( iy < cam_ny) )
        {
            const int idx_in = ix + iy*cam_nx;
            for (int i=0; i<3; ++i)
            {
                const int idx_out = ix + iy*cam_nx + i*cam_nx*cam_ny;
                XYZ[idx_out] += xyz_factor[i] * flux_camera[idx_in];
            }
        }
    }
    
    inline void gpu_assert(cudaError_t code, const char *file, int line, bool abort=true)
    {
        if (code != cudaSuccess)
        {
            fprintf(stderr,"CUDA_SAFE_CALL: %s %s %d\n", cudaGetErrorString(code), file, line);
            if (abort) exit(code);
        }
    }
    
    template<typename T>
    T* allocate_gpu(const int length)
    {
        T* data_ptr = Tools_gpu::allocate_gpu<T>(length);
    
        return data_ptr;
    }
    template<typename T>
    void copy_to_gpu(T* gpu_data, const T* cpu_data, const int length)
    {
        cuda_safe_call(cudaMemcpy(gpu_data, cpu_data, length*sizeof(T), cudaMemcpyHostToDevice));
    }
    
    
    template<typename T>
    void copy_from_gpu(T* cpu_data, const T* gpu_data, const int length)
    {
        cuda_safe_call(cudaMemcpy(cpu_data, gpu_data, length*sizeof(T), cudaMemcpyDeviceToHost));
    }
    
    template<typename TF>__global__
    void create_knull_grid(
            const int ncol_x, const int ncol_y, const int nz, const TF k_ext_null_min,
            const Optics_ext* __restrict__ k_ext, Grid_knull* __restrict__ k_null_grid)
    {   
        const int grid_x = blockIdx.x*blockDim.x + threadIdx.x;
        const int grid_y = blockIdx.y*blockDim.y + threadIdx.y;
        const int grid_z = blockIdx.z*blockDim.z + threadIdx.z;
        if ( ( grid_x < ngrid_h) && ( grid_y < ngrid_h) && ( grid_z < ngrid_v))
        {
            const TF fx = TF(ncol_x) / TF(ngrid_h);
            const TF fy = TF(ncol_y) / TF(ngrid_h);
            const TF fz = TF(nz) / TF(ngrid_v);

            const int x0 = grid_x*fx;
            const int x1 = floor((grid_x+1)*fx);
            const int y0 = grid_y*fy;
            const int y1 = floor((grid_y+1)*fy);
            const int z0 = grid_z*fz;
            const int z1 = floor((grid_z+1)*fz);
            
            const int ijk_grid = grid_x +grid_y*ngrid_h + grid_z*ngrid_h*ngrid_h;
            TF k_null_min = TF(1e15); // just a ridicilously high value 
            TF k_null_max = TF(0.);
            
            for (int k=z0; k<z1; ++k)
                for (int j=y0; j<y1; ++j)
                    for (int i=x0; i<x1; ++i)
                    {
                        const int ijk_in = i + j*ncol_x + k*ncol_x*ncol_y;
                        const TF k_ext_tot = k_ext[ijk_in].gas + k_ext[ijk_in].cloud;
                        k_null_min = min(k_null_min, k_ext_tot);
                        k_null_max = max(k_null_max, k_ext_tot);
                    }
            if (k_null_min == k_null_max) k_null_min = k_null_max * TF(0.99);
            k_null_grid[ijk_grid].k_min = k_null_min;
            k_null_grid[ijk_grid].k_max = k_null_max;
        }
    }


    template<typename TF>__global__
    void bundles_optical_props(
            const int ncol_x, const int ncol_y, const int nz, const TF dz_grid,
            const TF* __restrict__ tau_tot, const TF* __restrict__ ssa_tot, const TF* __restrict__ asy_tot, 
            const TF* __restrict__ tau_cld, const TF* __restrict__ ssa_cld,
            const TF rayleigh, 
            const TF* __restrict__ col_dry, const TF* __restrict__ vmr_h2o,
            Optics_ext* __restrict__ k_ext, Optics_scat* __restrict__ ssa_asy)
    {
        const int icol_x = blockIdx.x*blockDim.x + threadIdx.x;
        const int icol_y = blockIdx.y*blockDim.y + threadIdx.y;
        const int iz = blockIdx.z*blockDim.z + threadIdx.z;
        if ( ( icol_x < ncol_x) && ( icol_y < ncol_y) && ( iz < nz))
        {
            const int idx = icol_x + icol_y*ncol_x + iz*ncol_y*ncol_x; 
            const TF rayl_gas = rayleigh * (1 + vmr_h2o[idx]) * col_dry[idx] / dz_grid;
            const TF kext_cld = tau_cld[idx] / dz_grid;
            const TF rayl_cld = kext_cld * ssa_cld[idx];
            const TF kext_tot_old = tau_tot[idx] / dz_grid; 
            const TF kext_gas_old = kext_tot_old - kext_cld; 
            const TF kabs_gas = kext_gas_old - (kext_tot_old * ssa_tot[idx] - rayl_cld); 
            const TF kext_gas_new = kabs_gas + rayl_gas;
            //if (kext_cld < TF(1e-8))
            //{
            //    k_ext[idx].cloud = TF(1.4e-4);
            //    ssa_asy[idx].ssa = (rayl_gas + TF(0.9)*TF(1.4e-4)) / (kext_gas_new + TF(1.4e-4));
            //    ssa_asy[idx].asy = TF(0.5);
            //}
            //else
            //{
            //  k_ext[idx].cloud = kext_cld;
            //  k_ext[idx].gas =kext_gas_new;
            //  ssa_asy[idx].ssa = (rayl_gas + rayl_cld) / (kext_gas_new + kext_cld);
            //  ssa_asy[idx].asy =  asy_tot[idx];
            //}
            
            // if (kext_cld < TF(1e-8))
            // {
             //    k_ext[idx].cloud = TF(1.4e-6);
            //     k_ext[idx].gas = kext_gas_new;
             //    ssa_asy[idx].ssa = (rayl_gas + TF(0.9)*TF(1.4e-6)) / (kext_gas_new + TF(1.4e-6));
             //    ssa_asy[idx].asy = TF(0.5);
             //}
             //else
             //{
              k_ext[idx].cloud = kext_cld;
              k_ext[idx].gas = kext_gas_new;
              ssa_asy[idx].ssa = (rayl_gas + rayl_cld) / (kext_gas_new + kext_cld);
              ssa_asy[idx].asy =  asy_tot[idx];
            // }
        }
    }

    template<typename TF>__global__
    void background_profile(
            const int ncol_x, const int ncol_y, const int nz, const int nbg, 
            const TF* __restrict__ z_lev,
            const TF* __restrict__ tau_tot, const TF* __restrict__ ssa_tot, const TF* __restrict__ asy, 
            const TF* __restrict__ tau_cld, const TF* __restrict__ ssa_cld,
            const TF rayleigh, 
            const TF* __restrict__ col_dry, const TF* __restrict__ vmr_h2o,
            Optics_ext* __restrict__ k_ext_bg, Optics_scat* __restrict__ ssa_asy_bg, TF* __restrict__ z_lev_bg)
    {
        const int i = blockIdx.x * blockDim.x + threadIdx.x;
        if ( i < nbg)
        {
            const int idx_out = i;
            const int idx_in = (i+nz)*ncol_y*ncol_x;  
            const TF dz = abs(z_lev[i+nz+1] - z_lev[i+nz]);
            const TF rayl_gas = rayleigh * (1 + vmr_h2o[idx_in]) * col_dry[idx_in] / dz;
            
            //const TF kext_cld = tau_cld[idx] / dz_grid;
            //const TF rayl_cld = kext_cld * ssa_cld[idx]
            const TF kext_cld = TF(0.);//TF(1.4e-6);
            const TF rayl_cld = kext_cld * Float(0.9);
            const TF asy_in = TF(0.0);

            const TF kext_tot_old = tau_tot[idx_in] / dz; 
            const TF kext_gas_old = kext_tot_old - kext_cld; 
            const TF kabs_gas = kext_gas_old - (kext_tot_old * ssa_tot[idx_in] - rayl_cld); //(tau_tot[idx] / dz_grid - kext_cld) * (TF(1.) - ssa[idx]);
            const TF kext_gas_new = kabs_gas + rayl_gas;
            
        //    k_ext_bg[i].cloud = kext_cld;
        //    k_ext_bg[i].gas = kext_gas_new;
        //    ssa_asy_bg[i].ssa = (rayl_gas + rayl_cld) / (kext_gas_new + kext_cld);
        //    ssa_asy_bg[i].asy = asy_in; 
        //    z_lev_bg[i] = z_lev[i + nz];
            k_ext_bg[i].cloud = kext_cld;
            k_ext_bg[i].gas = kext_gas_new;
            ssa_asy_bg[i].ssa = (rayl_gas + rayl_cld) / (kext_gas_new + kext_cld);
            ssa_asy_bg[i].asy = asy[idx_in];//asy_in; 
            z_lev_bg[i] = z_lev[i + nz];
            if (i == nbg-1) z_lev_bg[i + 1] = z_lev[i + nz + 1];
        }
    }
    
    template<typename TF>__global__
    void count_to_flux_2d(
            const int cam_nx, const int cam_ny, const TF photons_per_col, const TF* __restrict__ toa_src, const TF toa_factor,
            const TF* __restrict__ count, TF* __restrict__ flux)
    {
        const int ix = blockIdx.x*blockDim.x + threadIdx.x;
        const int iy = blockIdx.y*blockDim.y + threadIdx.y;

        if ( ( ix < cam_nx) && ( iy < cam_ny) )
        {
            const int idx = ix + iy*cam_nx;
            const TF flux_per_ray = toa_src[0] * toa_factor / photons_per_col;
            flux[idx] = count[idx] * flux_per_ray;
        }
    }

}

template<typename TF>
Raytracer_gpu<TF>::Raytracer_gpu()
{
}

template<typename TF>
void Raytracer_gpu<TF>::add_xyz_camera(
    const int cam_nx, const int cam_ny,
    const Array_gpu<TF,1>& xyz_factor,
    const Array_gpu<TF,2>& flux_camera,
    Array_gpu<TF,3>& XYZ)
{
    const int block_x = 8;
    const int block_y = 8;

    const int grid_x  = cam_nx/block_x + (cam_nx%block_x > 0);
    const int grid_y  = cam_ny/block_y + (cam_ny%block_y > 0);

    dim3 grid(grid_x, grid_y);
    dim3 block(block_x, block_y);

    add_xyz_camera_kernel<<<grid, block>>>(
            cam_nx, cam_ny,
            xyz_factor.ptr(),
            flux_camera.ptr(),
            XYZ.ptr());

}

template<typename TF>
void Raytracer_gpu<TF>::normalize_xyz_camera(
    const int cam_nx, const int cam_ny,
    const TF total_source,
    Array_gpu<TF,3>& XYZ)
{
    const int block_x = 8;
    const int block_y = 8;

    const int grid_x  = cam_nx/block_x + (cam_nx%block_x > 0);
    const int grid_y  = cam_ny/block_y + (cam_ny%block_y > 0);

    dim3 grid(grid_x, grid_y);
    dim3 block(block_x, block_y);

    normalize_xyz_camera_kernel<<<grid, block>>>(
            cam_nx, cam_ny,
            total_source,
            XYZ.ptr());

}

template<typename TF>
void Raytracer_gpu<TF>::trace_rays(
        const Int photons_to_shoot,
        const int ncol_x, const int ncol_y, const int nz, const int nlay,
        const TF dx_grid, const TF dy_grid, const TF dz_grid,
        const Array_gpu<TF,1>& z_lev,
        const Optical_props_2str_gpu<TF>& optical_props,
        const Optical_props_2str_gpu<TF>& cloud_optical_props,
        const Array_gpu<TF,2>& surface_albedo,
        const TF zenith_angle,
        const TF azimuth_angle,
        const Array_gpu<TF,1>& toa_src,
        const TF toa_factor,
        const TF rayleigh,
        const Array_gpu<TF,2>& col_dry,
        const Array_gpu<TF,2>& vmr_h2o,
        Array_gpu<TF,2>& flux_camera)
{
    // set of block and grid dimensions used in data processing kernels - requires some proper tuning later
    const int block_col_x = 8;
    const int block_col_y = 8;
    const int block_z = 4;

    const int grid_col_x  = ncol_x/block_col_x + (ncol_x%block_col_x > 0);
    const int grid_col_y  = ncol_y/block_col_y + (ncol_y%block_col_y > 0);
    const int grid_z  = nz/block_z + (nz%block_z > 0);

    dim3 grid_2d(grid_col_x, grid_col_y);
    dim3 block_2d(block_col_x, block_col_y);
    dim3 grid_3d(grid_col_x, grid_col_y, grid_z);
    dim3 block_3d(block_col_x, block_col_y, block_z);

    // bundle optical properties in struct
    Array_gpu<Optics_ext,3> k_ext({ncol_x, ncol_y, nz});
    Array_gpu<Optics_scat,3> ssa_asy({ncol_x, ncol_y, nz});
    
    bundles_optical_props<<<grid_3d, block_3d>>>(
            ncol_x, ncol_y, nz, dz_grid,
            optical_props.get_tau().ptr(), optical_props.get_ssa().ptr(), optical_props.get_g().ptr(), 
            cloud_optical_props.get_tau().ptr(), cloud_optical_props.get_ssa().ptr(),
            rayleigh, col_dry.ptr(), vmr_h2o.ptr(), k_ext.ptr(), ssa_asy.ptr());
                                                                                
    // create k_null_grid
    const int block_kn_x = 8;
    const int block_kn_y = 8;
    const int block_kn_z = 4;

    const int grid_kn_x  = ngrid_h/block_kn_x + (ngrid_h%block_kn_x > 0);
    const int grid_kn_y  = ngrid_h/block_kn_y + (ngrid_h%block_kn_y > 0);
    const int grid_kn_z  = ngrid_v/block_kn_z + (ngrid_v%block_kn_z > 0);

    dim3 grid_kn(grid_kn_x, grid_kn_y, grid_kn_z);
    dim3 block_kn(block_kn_x, block_kn_y, block_kn_z);
    
    Array_gpu<Grid_knull,3> k_null_grid({ngrid_h, ngrid_h, ngrid_v});
    const TF k_ext_null_min = TF(1e-3);
    
    create_knull_grid<<<grid_kn, block_kn>>>(
            ncol_x, ncol_y, nz, k_ext_null_min,
            k_ext.ptr(), k_null_grid.ptr());
    
    // TOA-TOD profile (at x=0, y=0)
    const int nbg = nlay-nz;
    Array_gpu<Optics_ext,1> k_ext_bg({nbg});
    Array_gpu<Optics_scat,1> ssa_asy_bg({nbg});
    Array_gpu<TF,1> z_lev_bg({nbg+1});

    const int block_1d_z = 16;
    const int grid_1d_z  = nbg/block_1d_z + (nbg%block_1d_z > 0);
    dim3 grid_1d(grid_1d_z);
    dim3 block_1d(block_1d_z);
    
    background_profile<<<grid_1d, block_1d>>>(
            ncol_x, ncol_y, nz, nbg, z_lev.ptr(), 
            optical_props.get_tau().ptr(), optical_props.get_ssa().ptr(), optical_props.get_g().ptr(), 
            cloud_optical_props.get_tau().ptr(), cloud_optical_props.get_ssa().ptr(),
            rayleigh, col_dry.ptr(), vmr_h2o.ptr(), k_ext_bg.ptr(), ssa_asy_bg.ptr(), z_lev_bg.ptr());
    
    // initialise output arrays and set to 0
    const int cam_nx = flux_camera.dim(1);
    const int cam_ny = flux_camera.dim(2);
    
    Array_gpu<TF,2> camera_count({cam_nx, cam_ny});
    Array_gpu<TF,2> shot_count({cam_nx, cam_ny});
    Array_gpu<int,1> counter({1});
    
    rrtmgp_kernel_launcher_cuda::zero_array(cam_nx, cam_ny, camera_count);
    rrtmgp_kernel_launcher_cuda::zero_array(cam_nx, cam_ny, shot_count);
    rrtmgp_kernel_launcher_cuda::zero_array(1, counter);
    
    // domain sizes
    const TF x_size = ncol_x * dx_grid;
    const TF y_size = ncol_y * dy_grid;
    const TF z_size = nz * dz_grid;

    // direction of direct rays
    const TF dir_x = -std::sin(zenith_angle) * std::sin(azimuth_angle);
    const TF dir_y = -std::sin(zenith_angle) * std::cos(azimuth_angle);
    const TF dir_z = -std::cos(zenith_angle);

    const TF mu = std::abs(std::cos(zenith_angle));

    dim3 grid{grid_size}, block{block_size};
    Int photons_per_thread = photons_to_shoot / (grid_size * block_size);
    ray_tracer_kernel_bw<<<grid, block, nbg*sizeof(TF)>>>(
            photons_per_thread, k_null_grid.ptr(),
            camera_count.ptr(),
            shot_count.ptr(),
            counter.ptr(),
            cam_nx, cam_ny,
            k_ext.ptr(), ssa_asy.ptr(),
            k_ext_bg.ptr(), ssa_asy_bg.ptr(),
            z_lev_bg.ptr(),
            surface_albedo.ptr(),
            mu,
            x_size, y_size, z_size,
            dx_grid, dy_grid, dz_grid,
            dir_x, dir_y, dir_z,
            ncol_x, ncol_y, nz, nbg);
    
    //// convert counts to fluxes
    const int block_cam_x = 8;
    const int block_cam_y = 8;

    const int grid_cam_x  = cam_nx/block_cam_x + (cam_nx%block_cam_x > 0);
    const int grid_cam_y  = cam_ny/block_cam_y + (cam_ny%block_cam_y > 0);

    dim3 grid_cam(grid_cam_x, grid_cam_y);
    dim3 block_cam(block_cam_x, block_cam_y);

    const TF photons_per_col = TF(photons_to_shoot) / (cam_nx * cam_ny);
    count_to_flux_2d<<<grid_cam, block_cam>>>(
            cam_nx, cam_ny, photons_per_col,
            toa_src.ptr(),
            toa_factor,
            camera_count.ptr(), 
            flux_camera.ptr());

}       

#ifdef RTE_RRTMGP_SINGLE_PRECISION
template class Raytracer_gpu<float>;
#else
template class Raytracer_gpu<double>;
#endif

/*
 * This file is part of a C++ interface to the Radiative Transfer for Energetics (RTE)
 * and Rapid Radiative Transfer Model for GCM applications Parallel (RRTMGP).
 *
 * The original code is found at https://github.com/earth-system-radiation/rte-rrtmgp.
 *
 * Contacts: Robert Pincus and Eli Mlawer
 * email: rrtmgp@aer.com
 *
 * Copyright 2015-2020,  Atmospheric and Environmental Research and
 * Regents of the University of Colorado.  All right reserved.
 *
 * This C++ interface can be downloaded from https://github.com/earth-system-radiation/rte-rrtmgp-cpp
 *
 * Contact: Chiel van Heerwaarden
 * email: chiel.vanheerwaarden@wur.nl
 *
 * Copyright 2020, Wageningen University & Research.
 *
 * Use and duplication is permitted under the terms of the
 * BSD 3-clause license, see http://opensource.org/licenses/BSD-3-Clause
 *
 */

#ifndef GAS_CONCS_H
#define GAS_CONCS_H

#include <map>
#include <string>

#include "define_bool.h"

template<typename, int> class Array;

#ifdef __CUDACC__
template<typename> class Gas_concs_gpu;
#endif

template<typename TF>
class Gas_concs
{
    public:
        Gas_concs() {}
        Gas_concs(const Gas_concs& gas_concs_ref, const int start, const int size);

        // Insert new gas into the map.
        void set_vmr(const std::string& name, const TF data);
        void set_vmr(const std::string& name, const Array<TF,1>& data);
        void set_vmr(const std::string& name, const Array<TF,2>& data);

        // Insert new gas into the map.
        // void get_vmr(const std::string& name, Array<TF,2>& data) const;
        const Array<TF,2>& get_vmr(const std::string& name) const;

        // Check if gas exists in map.
        BOOL_TYPE exists(const std::string& name) const;

    private:
        std::map<std::string, Array<TF,2>> gas_concs_map;

        #ifdef __CUDACC__
        friend class Gas_concs_gpu<TF>;
        #endif
};

#ifdef __CUDACC__
template<typename, int> class Array_gpu;

template<typename TF>
class Gas_concs_gpu
{
    public:
        Gas_concs_gpu(const Gas_concs<TF>& gas_concs_ref);
        Gas_concs_gpu(const Gas_concs_gpu& gas_concs_ref, const int start, const int size);

        // Insert new gas into the map.
        // void set_vmr(const std::string& name, const TF data);
        // void set_vmr(const std::string& name, const Array<TF,1>& data);
        // void set_vmr(const std::string& name, const Array<TF,2>& data);

        // // Insert new gas into the map.
        // // void get_vmr(const std::string& name, Array<TF,2>& data) const;
        // const Array<TF,2>& get_vmr(const std::string& name) const;

        // // Check if gas exists in map.
        // BOOL_TYPE exists(const std::string& name) const;

    private:
        std::map<std::string, Array_gpu<TF,2>> gas_concs_map;
};
#endif

#endif

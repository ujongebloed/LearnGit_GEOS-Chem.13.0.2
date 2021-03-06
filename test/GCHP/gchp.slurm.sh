#!/bin/bash

#SBATCH -n 24
#SBATCH -N 1
#SBATCH -t 0-0:30
#SBATCH -p huce_cascade
#SBATCH --mem=110000
#SBATCH --mail-type=END

# Resource request tips: 
#  (1) Use #SBATCH -n 6 to request 6 cores total across all nodes
#  (2) Use #SBATCH --exclusive to prevent other users from sharing nodes in use
#      (ability to use --exclusive may be disabled on some clusters)
#  (3) Use --mem=50G to request 50 Gigabytes per node, 
#      or use --mem=MaxMemPerNode to request all memory per node
#  (4) Performance is enhanced by requesting entire nodes and all memory
#      even if GCHP is run on fewer cores per node than available.
#
# See SLURM documentation for descriptions of all possible settings.
# Type 'man sbatch' at the command prompt to browse documentation.

# Define GEOS-Chem log file (and remove any prior log file)
thisDir=$(pwd -P)
root=$(dirname ${thisDir})
runDir=$(basename ${thisDir})
log="${root}/logs/execute.${runDir}.log"
rm -f ${log}

# Make sure GCHP output restart file does not exist with the original name
# used by MAPL. Its present will cause GCHP run to fail. The output restart
# file is renamed after a successful run, but a file with the original name
# may persist if the previous run was unsuccessful.
if [[ -e gcchem_internal_checkpoint ]]; then
    rm gcchem_internal_checkpoint
fi

# Always remove cap_restart if not doing a multi-segmented run.
if [[ -e cap_restart ]]; then
   rm cap_restart
fi

# Update runConfig.sh to use 24 cores
sed -i -e "s/TOTAL_CORES=48/TOTAL_CORES=24/"               ./runConfig.sh
sed -i -e "s/NUM_NODES=2/NUM_NODES=1/"                     ./runConfig.sh
sed -i -e "s/NUM_CORES_PER_NODE=48/NUM_CORES_PER_NODE=24/" ./runConfig.sh

# Sync all config files with settings in runConfig.sh                           
source runConfig.sh > ${log}
if [[ $? == 0 ]]; then

    # Source your environment file. This requires first setting the gchp.env
    # symbolic link using script setEnvironment in the run directory. 
    # Be sure gchp.env points to the same file for both compilation and 
    # running. You can copy or adapt sample environment files located in 
    # ./envSamples subdirectory.
    gchp_env=$(readlink -f gchp.env)
    if [ ! -f ${gchp_env} ] 
    then
       echo "ERROR: gchp.env symbolic link is not set!"
       echo "Copy or adapt an environment file from the ./envSamples "
       echo "subdirectory prior to running. Then set the gchp.env "
       echo "symbolic link to point to it using ./setEnvironment.sh."
       echo "Exiting."
       exit 1
    fi
    echo " " >> ${log}
    echo "WARNING: You are using environment settings in ${gchp_env}" >> ${log}
    source ${gchp_env} >> ${log}

    # Use SLURM to distribute tasks across nodes
    NX=$( grep NX GCHP.rc | awk '{print $2}' )
    NY=$( grep NY GCHP.rc | awk '{print $2}' )
    coreCount=$(( ${NX} * ${NY} ))
    planeCount=$(( ${coreCount} / ${SLURM_NNODES} ))
    if [[ $(( ${coreCount} % ${SLURM_NNODES} )) > 0 ]]; then
	${planeCount}=$(( ${planeCount} + 1 ))
    fi

    # Echo info from computational cores to log file for displaying results
    echo "# of CPUs : ${coreCount}" >> ${log}
    echo "# of nodes: ${SLURM_NNODES}" >> ${log}
    echo "-m plane  : ${planeCount}" >> ${log}

    # Optionally compile 
    # Uncomment the line below to compile from scratch
    # See other compile options with 'make help'
    # make build_all

    # Echo start date
    echo ' ' >> ${log}
    echo '===> Run started at' `date` >> ${log}

    # Odyssey-specific setting to get around connection issues at high # cores
    export OMPI_MCL_btl=openib

    # Start the simulation
    time srun -n ${coreCount} -N ${SLURM_NNODES} -m plane=${planeCount} --mpi=pmix ./gchp >> ${log}

    # Rename the restart (checkpoint) file for clarity and to enable reuse as
    # a restart file. MAPL cannot read in a file with the same name as the
    # output checkpoint filename configured in GCHP.rc.
    if [ -f cap_restart ]; then
       restart_datetime=$(echo $(cat cap_restart) | sed 's/ /_/g')
       mv gcchem_internal_checkpoint gcchem_internal_checkpoint.restart.${restart_datetime}.nc4
    fi

    # Echo end date
    echo '===> Run ended at' `date` >> ${log}

else
    cat ${log}
fi

# Clear variable
unset log

# Update the results log
cd ..
./intTestResults.sh
cd ${thisDir}

# Exit normally
exit 0


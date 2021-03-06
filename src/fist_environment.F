!-----------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations         !
!   Copyright (C) 2000 - 2011  CP2K developers group                          !
!-----------------------------------------------------------------------------!

! *****************************************************************************
!> \brief initialize fist environment
!> \author CJM
! *****************************************************************************
MODULE fist_environment
  USE atomic_kind_list_types,          ONLY: atomic_kind_list_create,&
                                             atomic_kind_list_release,&
                                             atomic_kind_list_type
  USE atomic_kind_types,               ONLY: atomic_kind_type,&
                                             get_atomic_kind_set
  USE cell_types,                      ONLY: cell_release,&
                                             cell_type,&
                                             get_cell,&
                                             read_cell,&
                                             write_cell
  USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                             cp_print_key_unit_nr
  USE cp_para_types,                   ONLY: cp_para_env_type
  USE cp_subsys_methods,               ONLY: cp_subsys_read_colvar
  USE cp_subsys_types,                 ONLY: cp_subsys_create,&
                                             cp_subsys_release,&
                                             cp_subsys_set,&
                                             cp_subsys_type
  USE cp_symmetry,                     ONLY: write_symmetry
  USE distribution_1d_types,           ONLY: distribution_1d_release,&
                                             distribution_1d_type
  USE distribution_methods,            ONLY: distribute_molecules_1d
  USE ewald_environment_types,         ONLY: ewald_env_create,&
                                             ewald_env_release,&
                                             ewald_env_set,&
                                             ewald_environment_type,&
                                             read_ewald_section
  USE ewald_pw_methods,                ONLY: ewald_pw_grid_change
  USE ewald_pw_types,                  ONLY: ewald_pw_create,&
                                             ewald_pw_release,&
                                             ewald_pw_type
  USE exclusion_types,                 ONLY: exclusion_type
  USE f77_blas
  USE fist_energy_types,               ONLY: allocate_fist_energy,&
                                             fist_energy_type
  USE fist_environment_types,          ONLY: fist_env_get,&
                                             fist_env_set,&
                                             fist_environment_type
  USE fist_nonbond_env_types,          ONLY: fist_nonbond_env_release,&
                                             fist_nonbond_env_type
  USE force_fields,                    ONLY: force_field_control
  USE header,                          ONLY: fist_header
  USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                             section_vals_type
  USE kinds,                           ONLY: dp
  USE mol_kind_new_list_types,         ONLY: mol_kind_new_list_create,&
                                             mol_kind_new_list_release,&
                                             mol_kind_new_list_type
  USE mol_new_list_types,              ONLY: mol_new_list_create,&
                                             mol_new_list_release,&
                                             mol_new_list_type
  USE molecule_kind_types,             ONLY: molecule_kind_type,&
                                             write_molecule_kind_set
  USE molecule_types_new,              ONLY: molecule_type
  USE multipole_types,                 ONLY: create_multipole_type,&
                                             multipole_type,&
                                             release_multipole_type
  USE particle_list_types,             ONLY: particle_list_create,&
                                             particle_list_release,&
                                             particle_list_type
  USE particle_types,                  ONLY: particle_type,&
                                             write_fist_particle_coordinates,&
                                             write_particle_distances,&
                                             write_structure_data
  USE qmmm_types,                      ONLY: qmmm_env_mm_type
  USE timings,                         ONLY: timeset,&
                                             timestop
  USE topology,                        ONLY: topology_control
#include "cp_common_uses.h"

  IMPLICIT NONE

  PRIVATE

  CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'fist_environment'
  PUBLIC :: fist_init

CONTAINS
! *****************************************************************************
!> \brief reads the input and database file for fist
!> \par Used By
!>      fist_main
! *****************************************************************************
  SUBROUTINE fist_init ( fist_env, root_section,para_env, force_env_section,&
       subsys_section, use_motion_section, error )

    TYPE(fist_environment_type), POINTER     :: fist_env
    TYPE(section_vals_type), POINTER         :: root_section
    TYPE(cp_para_env_type), POINTER          :: para_env
    TYPE(section_vals_type), POINTER         :: force_env_section, &
                                                subsys_section
    LOGICAL, INTENT(IN)                      :: use_motion_section
    TYPE(cp_error_type), INTENT(inout)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'fist_init', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: handle, iw
    LOGICAL                                  :: failure, qmmm, &
                                                shell_adiabatic, shell_present
    REAL(KIND=dp), DIMENSION(3)              :: abc
    TYPE(atomic_kind_list_type), POINTER     :: atomic_kinds
    TYPE(atomic_kind_type), DIMENSION(:), &
      POINTER                                :: atomic_kind_set
    TYPE(cell_type), POINTER                 :: cell, cell_ref
    TYPE(cp_logger_type), POINTER            :: logger
    TYPE(cp_subsys_type), POINTER            :: subsys
    TYPE(ewald_environment_type), POINTER    :: ewald_env
    TYPE(exclusion_type), DIMENSION(:), &
      POINTER                                :: exclusions
    TYPE(fist_nonbond_env_type), POINTER     :: fist_nonbond_env
    TYPE(mol_kind_new_list_type), POINTER    :: mol_kinds
    TYPE(mol_new_list_type), POINTER         :: mols
    TYPE(molecule_kind_type), DIMENSION(:), &
      POINTER                                :: molecule_kind_set
    TYPE(molecule_type), DIMENSION(:), &
      POINTER                                :: molecule_set
    TYPE(particle_list_type), POINTER        :: core_particles, particles, &
                                                shell_particles
    TYPE(particle_type), DIMENSION(:), &
      POINTER                                :: core_particle_set, &
                                                particle_set, &
                                                shell_particle_set
    TYPE(qmmm_env_mm_type), POINTER          :: qmmm_env
    TYPE(section_vals_type), POINTER         :: cell_section, colvar_section, &
                                                ewald_section, mm_section, &
                                                poisson_section

    CALL timeset(routineN,handle)
    failure = .FALSE.
    logger => cp_error_get_logger(error)

    NULLIFY ( subsys, molecule_kind_set, molecule_set, atomic_kind_set,&
         particle_set,atomic_kinds,particles,mols,mol_kinds,cell,cell_ref)
    NULLIFY ( ewald_env, fist_nonbond_env, qmmm_env, cell_section, &
         poisson_section, shell_particle_set, shell_particles, &
         core_particle_set, core_particles, exclusions)
    IF (.NOT.ASSOCIATED(subsys_section)) THEN
       subsys_section => section_vals_get_subs_vals(force_env_section,"SUBSYS",error=error)
    END IF
    mm_section => section_vals_get_subs_vals(force_env_section,"MM",error=error)
    cell_section => section_vals_get_subs_vals(subsys_section,"CELL",error=error)
    poisson_section => section_vals_get_subs_vals(mm_section,"POISSON",error=error)
    ewald_section => section_vals_get_subs_vals(poisson_section,"EWALD",error=error)

    CALL fist_env_set(fist_env,input=force_env_section,error=error)

    iw = cp_print_key_unit_nr(logger,mm_section,"PRINT%PROGRAM_BANNER",&
         extension=".mmLog",error=error)
    CALL fist_header(iw)
    CALL cp_print_key_finished_output(iw,logger,mm_section,"PRINT%PROGRAM_BANNER",error=error)

    CALL cp_subsys_create ( subsys, para_env = para_env, error = error )

    ! read colvars and add to subsys
    colvar_section => section_vals_get_subs_vals(subsys_section,"COLVAR",error=error)
    CALL cp_subsys_read_colvar( subsys, colvar_section, error=error)

    CALL read_cell( cell, cell_ref, cell_section=cell_section, para_env=para_env, error=error)
    CALL get_cell (cell, abc=abc)

    ! Print the cell parameters
    CALL write_cell ( cell, subsys_section, cell_ref, error=error)

    ! Create the ewald environment
    CALL ewald_env_create ( ewald_env, para_env, error )

    ! Read the input section and set the ewald_env
    CALL read_ewald_section ( ewald_env, ewald_section,error )
    CALL ewald_env_set(ewald_env, poisson_section=poisson_section, error=error)

    CALL fist_env_get (fist_env, qmmm=qmmm, qmmm_env=qmmm_env, error=error)
    ! Topology
    CALL topology_control ( atomic_kind_set, particle_set, molecule_kind_set, molecule_set,&
                            subsys%colvar_p, subsys%gci, root_section, para_env, qmmm=qmmm,&
                            qmmm_env=qmmm_env, force_env_section=force_env_section,&
                            subsys_section=subsys_section,use_motion_section=use_motion_section,&
                            exclusions=exclusions, error=error)
    CALL fist_env_set(fist_env, exclusions=exclusions, error=error)

    CALL force_field_control ( atomic_kind_set, particle_set, molecule_kind_set, molecule_set,&
                               ewald_env, fist_nonbond_env, root_section, para_env, qmmm=qmmm,&
                               qmmm_env=qmmm_env, subsys_section=subsys_section,&
                               mm_section=mm_section, shell_particle_set=shell_particle_set, &
                               core_particle_set=core_particle_set, cell=cell, error=error )

    CALL particle_list_create ( particles, els_ptr = particle_set, error = error )
    NULLIFY(shell_particles)
    NULLIFY(core_particles)
    IF(ASSOCIATED(shell_particle_set)) THEN
       CALL particle_list_create ( shell_particles, els_ptr = shell_particle_set, error = error )
    END IF
    IF(ASSOCIATED(core_particle_set)) THEN
       CALL particle_list_create ( core_particles, els_ptr = core_particle_set, error = error )
    END IF
    CALL get_atomic_kind_set(atomic_kind_set=atomic_kind_set,&
                             shell_present=shell_present, shell_adiabatic=shell_adiabatic)
    CALL fist_env_set(fist_env, shell_model=shell_present, &
                      shell_model_ad=shell_adiabatic, error=error)
    CALL atomic_kind_list_create ( atomic_kinds, els_ptr = atomic_kind_set, error = error )
    CALL mol_new_list_create ( mols, els_ptr = molecule_set, error = error )
    CALL mol_kind_new_list_create ( mol_kinds, els_ptr = molecule_kind_set, error = error )
    CALL cp_subsys_set ( subsys, particles = particles, atomic_kinds = atomic_kinds, &
                         molecules_new = mols, molecule_kinds_new = mol_kinds, &
                         shell_particles=shell_particles, core_particles=core_particles,&
                         error = error )
    CALL particle_list_release ( particles, error = error )
    CALL particle_list_release ( shell_particles, error = error )
    CALL particle_list_release ( core_particles, error = error )
    CALL atomic_kind_list_release ( atomic_kinds, error = error )
    CALL mol_new_list_release ( mols, error = error )
    CALL mol_kind_new_list_release ( mol_kinds, error = error )

    CALL fist_init_subsys ( fist_env, subsys, cell, cell_ref, fist_nonbond_env, ewald_env,&
                            force_env_section, subsys_section,error )

    CALL cell_release(cell,error=error)
    CALL cell_release(cell_ref,error=error)
    CALL ewald_env_release ( ewald_env, error )
    CALL fist_nonbond_env_release ( fist_nonbond_env, error )
    CALL cp_subsys_release(subsys,error=error)

    CALL timestop(handle)

  END SUBROUTINE fist_init

! *****************************************************************************
!> \brief   Read the input and the database files for the setup of the
!>          FIST environment.
!> \author  MK
!> \date    22.05.2000
!> \version 1.0
! *****************************************************************************
  SUBROUTINE fist_init_subsys ( fist_env, subsys, cell, cell_ref, fist_nonbond_env,&
                                ewald_env, force_env_section, subsys_section, error )

    TYPE(fist_environment_type), POINTER     :: fist_env
    TYPE(cp_subsys_type), POINTER            :: subsys
    TYPE(cell_type), POINTER                 :: cell, cell_ref
    TYPE(fist_nonbond_env_type), POINTER     :: fist_nonbond_env
    TYPE(ewald_environment_type), POINTER    :: ewald_env
    TYPE(section_vals_type), POINTER         :: force_env_section, &
                                                subsys_section
    TYPE(cp_error_type), INTENT(INOUT)       :: error

    CHARACTER(len=*), PARAMETER :: routineN = 'fist_init_subsys', &
      routineP = moduleN//':'//routineN

    INTEGER                                  :: handle
    TYPE(atomic_kind_type), DIMENSION(:), &
      POINTER                                :: atomic_kind_set
    TYPE(distribution_1d_type), POINTER      :: local_molecules, &
                                                local_particles
    TYPE(ewald_pw_type), POINTER             :: ewald_pw
    TYPE(fist_energy_type), POINTER          :: thermo
    TYPE(molecule_kind_type), DIMENSION(:), &
      POINTER                                :: molecule_kind_set
    TYPE(molecule_type), DIMENSION(:), &
      POINTER                                :: molecule_set
    TYPE(multipole_type), POINTER            :: multipoles
    TYPE(particle_type), DIMENSION(:), &
      POINTER                                :: particle_set
    TYPE(section_vals_type), POINTER         :: grid_print_section

    CALL timeset(routineN,handle)
    NULLIFY ( thermo, ewald_pw, local_molecules, local_particles, multipoles)
    particle_set => subsys % particles % els
    atomic_kind_set => subsys % atomic_kinds % els
    molecule_set => subsys % molecules_new % els
    molecule_kind_set => subsys % molecule_kinds_new % els
    
    ! Create the fist_energy_type
    CALL allocate_fist_energy( thermo )
    
    ! Print the molecule kind set
    CALL write_molecule_kind_set(molecule_kind_set,subsys_section,error)
    
    ! Print the atomic coordinates
    CALL write_fist_particle_coordinates(particle_set,subsys_section, &
                                         fist_nonbond_env%charges, error)
    CALL write_particle_distances(particle_set,cell,subsys_section,error)
    CALL write_structure_data(particle_set, cell=cell, input_section=subsys_section, error=error)

    ! Print symmetry information
    CALL write_symmetry(particle_set,cell,subsys_section,error)
    
    ! Distribute molecules and atoms using the new data structures ***
    CALL distribute_molecules_1d ( particle_kind_set=atomic_kind_set,&
                                   particle_set=particle_set,&
                                   local_particles=local_particles,&
                                   molecule_kind_set=molecule_kind_set,&
                                   molecule_set=molecule_set,&
                                   local_molecules=local_molecules,&
                                   force_env_section=force_env_section,&
                                   error=error )
    
    ! Create ewald grids
    grid_print_section => section_vals_get_subs_vals(force_env_section,&
         "PRINT%GRID_INFORMATION",error=error)
    CALL ewald_pw_create ( ewald_pw, ewald_env, cell, cell_ref, grid_print_section, error )
       
    ! Initialize ewald grids
    CALL ewald_pw_grid_change ( ewald_pw, ewald_env, cell, error )
    
    ! Possibly Initialize the multipole environment
    CALL create_multipole_type(multipoles, particle_set, subsys_section, ewald_env, error)
    CALL cp_subsys_set(subsys, multipoles=multipoles, error=error)

    ! Set the fist_env
    CALL fist_env_set ( fist_env = fist_env, subsys = subsys, error = error )
    CALL fist_env_set ( fist_env=fist_env,&
                        cell=cell, cell_ref=cell_ref, &
                        local_molecules=local_molecules,&
                        local_particles=local_particles,&
                        ewald_env=ewald_env, ewald_pw=ewald_pw, &
                        fist_nonbond_env=fist_nonbond_env,&
                        thermo=thermo ,error=error)
    
    CALL distribution_1d_release(local_particles, error=error)
    CALL distribution_1d_release(local_molecules, error=error)
    CALL ewald_pw_release(ewald_pw, error)
    CALL release_multipole_type(multipoles, error)
    CALL timestop(handle)
    
  END SUBROUTINE fist_init_subsys
END MODULE fist_environment

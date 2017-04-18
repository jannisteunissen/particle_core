! Jannis Teunissen, Casper Rutjes
!
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.

!> Module that adds photo ionization functionallity to particle core
module m_photoi
  use m_random
  use m_particle_core
  use m_units_constants
  use m_gas

  implicit none
  private

  integer, parameter                     :: dp = kind(0.0d0)
  
  ! photo ionization settings
  real(dp)                               :: pi_quench_fac
  real(dp)                               :: pi_min_inv_abs_len, pi_max_inv_abs_len
  real(dp), dimension(:, :), allocatable :: pi_photo_eff_table
  type(RNG_t)                            :: pi_rng
    
  type(PC_t), pointer                    :: pi_pc
  
  public :: PI_initialize
contains
  
  subroutine pi_link(my_pc)
    type(PC_t), intent(in), target :: my_pc 
    pi_pc => my_pc
  end subroutine
  
  !> After the first argument, if argument is present then overwrite default
  subroutine PI_initialize(my_pc,                &
                           quench_fac,           &
                           min_inv_abs_len_resc, &
                           max_inv_abs_len_resc, &
                           size_photo_eff_table, &
                           photo_eff_table,      &
                           rng_seed)
   type(PC_t), intent(in)                      :: my_pc
   real(dp), intent(in), optional              :: quench_fac
   real(dp), intent(in), optional              :: min_inv_abs_len_resc
   real(dp), intent(in), optional              :: max_inv_abs_len_resc
   integer, intent(in), optional               :: size_photo_eff_table
   real(dp), intent(in), allocatable,optional  :: photo_eff_table(:,:)
   integer, intent(in), optional               :: rng_seed(4)
   
   integer, parameter            :: i8 = selected_int_kind(18)
   integer(i8)                   :: rng_seed_8byte(2)

   call pi_link(my_pc)
   
   !> Check if GAS is initialized
   if (GAS_initialized .eqv. .false.) then
     print *, "Initialize GAS before PI"
     stop
   end if
    
    !> Check oxygen concentration
    if (GAS_get_fraction("O2") <= epsilon(1.0_dp)) then
       print *, "There is no oxygen, you should disable photoionization"
       stop
    end if

    pi_quench_fac = (30.0D0 * UC_torr_to_bar) / &
         (GAS_pressure + (30.0D0 * UC_torr_to_bar))
    if (present(quench_fac)) pi_quench_fac = pi_quench_fac
    
    
    if (present(min_inv_abs_len_resc)) then
      pi_min_inv_abs_len = min_inv_abs_len_resc * GAS_get_fraction("O2") * GAS_pressure
    else
      pi_min_inv_abs_len = 3.5D0 * GAS_get_fraction("O2") * GAS_pressure
    end if
    
    if (present(max_inv_abs_len_resc)) then
      pi_max_inv_abs_len = max_inv_abs_len_resc * GAS_get_fraction("O2") * GAS_pressure
    else
      pi_max_inv_abs_len = 200D0 * GAS_get_fraction("O2") * GAS_pressure
    end if
  
    if (present(size_photo_eff_table) .and. present(photo_eff_table)) then
      allocate(pi_photo_eff_table(2,size_photo_eff_table))
      pi_photo_eff_table = photo_eff_table
    else
        allocate(pi_photo_eff_table(2,6))
        pi_photo_eff_table(1,:) = [0.0D0, 0.25D7,  0.4D7, 0.75D7,  1.5D7, 3.75D7]
        pi_photo_eff_table(2,:) = [0.0D0, 0.05D0, 0.12D0, 0.08D0, 0.06D0, 0.04D0]
    end if
  
    if (present(rng_seed)) then
       rng_seed_8byte = transfer(rng_seed, rng_seed_8byte)
       call pi_rng%set_seed(rng_seed_8byte)
    else
       call pi_rng%set_seed([8972134_i8, 21384823409_i8])
    end if  

    call pi_pc%add_ionization_callback(ionization_do_photoi)
  end subroutine PI_initialize
  
  !> Ionization callback procedure
  subroutine ionization_do_photoi(my_part, c_ix, c_type)
    type(PC_part_t), intent(in) :: my_part
    integer, intent(in)         :: c_ix, c_type
    
    ! dummy
    type(PC_part_t)                      :: my_new_part
    real(dp)                             :: mean_gammas, en_frac, fly_len
    real(dp)                             :: fld, psi, chi, x_end(3)
    integer                              :: n, n_photons


    fld         = norm2(my_part%a / UC_elec_q_over_m)
    mean_gammas = get_photoi_eff(fld) * my_part%w * pi_quench_fac
    n_photons   = pi_rng%poisson(mean_gammas)

    do n = 1, n_photons
       ! Select random direction and absorption length
       en_frac  = pi_rng%unif_01()
       fly_len  = -log(1.0_dp - pi_rng%unif_01()) / get_photoi_lambda(en_frac)
       psi      = 2 * UC_pi * pi_rng%unif_01()
       chi      = acos(1.0_dp - 2 * pi_rng%unif_01())

       my_new_part%x(1)   = my_part%x(1) + fly_len * sin(chi) * cos(psi)
       my_new_part%x(2)   = my_part%x(2) + fly_len * sin(chi) * sin(psi)
       my_new_part%x(3)   = my_part%x(3) + fly_len * cos(chi)
       my_new_part%v      = [0.0D0, 0.0D0, 0.0D0]
       my_new_part%a      = [0.0D0, 0.0D0, 0.0D0]
       my_new_part%w      = 1.0D0
       my_new_part%t_left = 0.0D0
       
       if (pi_pc%outside_check(my_new_part) .eqv. .false.) then
         call pi_pc%add_part(my_new_part)
       end if
    end do
  end subroutine ionization_do_photoi

  ! Returns the photo-efficiency coefficient corresponding to an electric
  ! field of strength fld
  real(dp) function get_photoi_eff(fld)
    use m_lookup_table
    real(dp), intent(in) :: fld
    call LT_lin_interp_list(pi_photo_eff_table(1,:), &
         pi_photo_eff_table(2,:), fld, get_photoi_eff)
  end function get_photoi_eff

   ! Returns the inverse mean free path for a photon.
   real(dp) function get_photoi_lambda(en_frac)
    real(dp), intent(in) :: en_frac
      get_photoi_lambda = pi_min_inv_abs_len * &
           (pi_max_inv_abs_len/pi_min_inv_abs_len)**en_frac
   end function get_photoi_lambda
end module m_photoi
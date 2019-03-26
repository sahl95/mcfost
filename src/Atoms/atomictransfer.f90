! ----------------------------------------------------------------------------------- !
! ----------------------------------------------------------------------------------- !
! This module solves for the radiative transfer equation by ray-tracing for
! multi-level atoms, using the MALI scheme.
!
! Outputs:
! - Flux (\lambda) [J.s^{-1}.m^{-2}.Hz^{-1}]
! - Irradiation map around a line [J.s^{-1}.m^{-2}.Hz^{-1}.pix^{-1}] !sr^{-1}
!
!
! Note: SI units, velocity in m/s, density in kg/m3, radius in m
! ----------------------------------------------------------------------------------- !
! ----------------------------------------------------------------------------------- !

MODULE AtomicTransfer

 use metal, only                        : Background, BackgroundContinua, BackgroundLines
 use opacity
 use Profiles
 use spectrum_type
 use atmos_type
 use readatom
 use lte
 use constant, only 					: MICRON_TO_NM
 use collision
 use solvene
 use statequil_atoms
 use writeatom
 use simple_models, only 				: magneto_accretion_model, uniform_law_model
 !$ use omp_lib

 !MCFOST's original modules
 use input
 use parametres
 use grid
 use optical_depth, only				: atom_optical_length_tot, optical_length_tot
 use dust_prop
 use dust_transfer, only 				: compute_stars_map
 use dust_ray_tracing, only 			: init_directions_ray_tracing ,            &
                              			  tab_u_RT, tab_v_RT, tab_w_RT, tab_RT_az, &
                              			  tab_RT_incl, stars_map, kappa, stars_map_cont
 use stars
 use wavelengths
 use density

 IMPLICIT NONE
 
 PROCEDURE(INTEG_RAY_LINE_I), pointer :: INTEG_RAY_LINE => NULL()
 
 !Try to give a good idea to the user on how much RAM memory will be used
 integer :: Total_size_1 = 0, Total_size_2 = 0

 CONTAINS
 
 SUBROUTINE INTEG_RAY_LINE_I(id,icell_in,x,y,z,u,v,w,iray,labs)
 ! ------------------------------------------------------------------------------- !
  ! This routine performs integration of the transfer equation along a ray
  ! crossing different cells.
  ! --> Atomic Lines case.
  !
  ! voir integ_ray_mol from mcfost
  ! All necessary quantities are initialised before this routine, and everything
  ! call, update, rewrite atoms% and spectrum%
  ! if atmos%nHtot or atmos%T is 0, the cell is empty
  !
  ! id = processor information, iray = index of the running ray
  ! what is labs? lsubtract_avg?
 ! ------------------------------------------------------------------------------- !

  integer, intent(in) :: id, icell_in, iray
  double precision, intent(in) :: u,v,w
  double precision, intent(in) :: x,y,z
  logical, intent(in) :: labs !used in NLTE but why?
  double precision :: x0, y0, z0, x1, y1, z1, l, l_contrib, l_void_before
  double precision, dimension(NLTEspec%Nwaves) :: Snu, Snu_c
  double precision, dimension(NLTEspec%Nwaves) :: tau, tau_c, dtau_c, dtau
  integer :: nbr_cell, icell, next_cell, previous_cell, icell_star, i_star
  double precision :: facteur_tau !used only in molecular line to have emission for one
                                  !  half of the disk only. Note used in AL-RT.
                                  !  this is passed through the lonly_top or lonly_bottom.
  logical :: lcellule_non_vide, lsubtract_avg, lintersect_stars, get_wlam

  x1=x;y1=y;z1=z
  x0=x;y0=y;z0=z
  next_cell = icell_in
  nbr_cell = 0

  tau = 0.0_dp !go from surface down to the star
  tau_c = 0.0_dp

  ! Reset, because when we compute the flux map
  ! with emission_line_map, we only use one ray, iray=1
  ! and the same space is used for emergent I.
  ! Therefore it is needed to reset it.
  NLTEspec%I(:,iray,id) = 0d0
  NLTEspec%Ic(:,iray,id) = 0d0
  ! -------------------------------------------------------------- !
  !*** propagation dans la grille ***!
  ! -------------------------------------------------------------- !
  ! Will the ray intersect a star
  call intersect_stars(x,y,z, u,v,w, lintersect_stars, i_star, icell_star)

  ! Boucle infinie sur les cellules
  infinie : do ! Boucle infinie
    ! Indice de la cellule
    icell = next_cell
    x0=x1 ; y0=y1 ; z0=z1

    if (icell <= n_cells) then
     !lcellule_non_vide=.true.
     lcellule_non_vide = atmos%lcompute_atomRT(icell)
    else
     lcellule_non_vide=.false.
    endif

    ! Test sortie ! "The ray has reach the end of the grid"
    if (test_exit_grid(icell, x0, y0, z0)) RETURN
    if (lintersect_stars) then
      if (icell == icell_star) RETURN
    endif

    nbr_cell = nbr_cell + 1

    ! Calcul longeur de vol et profondeur optique dans la cellule
    previous_cell = 0 ! unused, just for Voronoi

    call cross_cell(x0,y0,z0, u,v,w,  icell, previous_cell, x1,y1,z1, next_cell, &
                     l, l_contrib, l_void_before)


!     if (.not.atmos%lcompute_atomRT(icell)) lcellule_non_vide = .false. !chi and chi_c = 0d0, cell is transparent  
!	   this makes the code to break down  --> the atomRT is defined on n_cells
!		but the infinite loop runs over "virtual" cells, which can be be 
!		out of atomRT boundary

    !count opacity only if the cell is filled, else go to next cell
    if (lcellule_non_vide) then
     lsubtract_avg = ((nbr_cell == 1).and.labs) !not used yet
     ! opacities in m^-1
     l_contrib = l_contrib * AU_to_m !l_contrib in AU
     if ((nbr_cell == 1).and.labs)  ds(iray,id) = l * AU_to_m !we enter at the cell, icell_in
     														  !and we need to compute the length path
     
     CALL initAtomOpac(id) !set opac to 0 for this cell and thread id
     !! Compute background opacities for PASSIVE bound-bound and bound-free transitions
     !! at all wavelength points including vector fields in the bound-bound transitions
     get_wlam = (labs .and. (nbr_cell == 1))
     CALL NLTEopacity(id, icell, x0, y0, z0, x1, y1, z1, u, v, w, l, get_wlam)
     !never enter NLTEopacity if no activeatoms
     if (lstore_opac) then !not updated during NLTE loop, just recomputed using initial pops
      CALL BackgroundLines(id, icell, x0, y0, z0, x1, y1, z1, u, v, w, l)
      dtau(:)   = l_contrib * (NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id)+&
                    NLTEspec%AtomOpac%Kc(icell,:,1))
      dtau_c(:) = l_contrib * NLTEspec%AtomOpac%Kc(icell,:,1)
      Snu = (NLTEspec%AtomOpac%jc(icell,:) + &
               NLTEspec%AtomOpac%eta_p(:,id) + NLTEspec%AtomOpac%eta(:,id) + &
                  NLTEspec%AtomOpac%Kc(icell,:,2) * NLTEspec%J(:,id)) / &
                 (NLTEspec%AtomOpac%Kc(icell,:,1) + &
                 NLTEspec%AtomOpac%chi_p(:,id) + NLTEspec%AtomOpac%chi(:,id) + 1d-300)

      Snu_c = (NLTEspec%AtomOpac%jc(icell,:) + &
            NLTEspec%AtomOpac%Kc(icell,:,2) * NLTEspec%Jc(:,id)) / &
            (NLTEspec%AtomOpac%Kc(icell,:,1) + 1d-300)
     else
      CALL Background(id, icell, x0, y0, z0, x1, y1, z1, u, v, w, l) !x,y,z,u,v,w,x1,y1,z1
                                !define the projection of the vector field (velocity, B...)
                                !at each spatial location.

      ! Epaisseur optique
      ! chi_p contains both thermal and continuum scattering extinction
      dtau(:)   =  l_contrib * (NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id))
      dtau_c(:) = l_contrib * NLTEspec%AtomOpac%chi_c(:,id)

      ! Source function
      ! No dust yet
      ! J and Jc are the mean radiation field for total and continuum intensities
      ! it multiplies the continuum scattering coefficient for isotropic (unpolarised)
      ! scattering. chi, eta are opacity and emissivity for ACTIVE lines.
      Snu = (NLTEspec%AtomOpac%eta_p(:,id) + NLTEspec%AtomOpac%eta(:,id) + &
                  NLTEspec%AtomOpac%sca_c(:,id) * NLTEspec%J(:,id)) / &
                 (NLTEspec%AtomOpac%chi_p(:,id) + NLTEspec%AtomOpac%chi(:,id) + 1d-300)


      ! continuum source function
      Snu_c = (NLTEspec%AtomOpac%eta_c(:,id) + &
            NLTEspec%AtomOpac%sca_c(:,id) * NLTEspec%Jc(:,id)) / &
            (NLTEspec%AtomOpac%chi_c(:,id) + 1d-300)
    end if
    !In ray-traced map (which is used this subroutine) we integrate from the observer
    ! to the source(s), but we actually get the outgoing intensity/flux. Direct
    !intgreation of the RTE from the observer to the source result in having the
    ! inward flux and intensity. Integration from the source to the observer is done
    ! when computing the mean intensity: Sum_ray I*exp(-dtau)+S*(1-exp(-dtau))
    ! NLTEspec%I(:,iray,id) = NLTEspec%I(:,iray,id) + dtau*Snu*dexp(-tau)
    ! NLTEspec%Ic(:,iray,id) = NLTEspec%Ic(:,iray,id) + dtau_c*Snu_c*dexp(-tau_c)
    NLTEspec%I(:,iray,id) = NLTEspec%I(:,iray,id) + &
                             exp(-tau) * (1.0_dp - exp(-dtau)) * Snu
    NLTEspec%Ic(:,iray,id) = NLTEspec%Ic(:,iray,id) + &
                             exp(-tau_c) * (1.0_dp - exp(-dtau_c)) * Snu_c

!      !!surface superieure ou inf, not used with AL-RT
     facteur_tau = 1.0
!      if (lonly_top    .and. z0 < 0.) facteur_tau = 0.0
!      if (lonly_bottom .and. z0 > 0.) facteur_tau = 0.0

     ! Mise a jour profondeur optique pour cellule suivante
     ! dtau = chi * ds
     tau = tau + dtau * facteur_tau
     tau_c = tau_c + dtau_c

    !! calcule les poids d'integration pour chaque raies aussi ???
    if ((nbr_cell == 1).and.labs) then 
     if (lstore_opac) then
      !NLTEspec%Psi(:, iray, id) = 1d0 - (1d0 - dexp(-ds(iray,id)))/ds(iray,id)
      NLTEspec%Psi(:,iray,id) = (1d0 - &
      	dexp(-ds(iray,id)*(NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id)+&
                    NLTEspec%AtomOpac%Kc(icell,:,1))) ) / &
                    (NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id)+&
                    NLTEspec%AtomOpac%Kc(icell,:,1))
     else
       NLTEspec%Psi(:,iray,id) = (1d0 - &
      	dexp(-ds(iray,id)*(NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id)))) / &
      							(NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id))
     end if
    end if

    end if  ! lcellule_non_vide
  end do infinie
  ! -------------------------------------------------------------- !
  ! -------------------------------------------------------------- !
  RETURN
  END SUBROUTINE INTEG_RAY_LINE_I
  
 SUBROUTINE INTEG_RAY_LINE_Z(id,icell_in,x,y,z,u,v,w,iray,labs)
 ! ------------------------------------------------------------------------------- !
 ! ------------------------------------------------------------------------------- !

  integer, intent(in) :: id, icell_in, iray
  double precision, intent(in) :: u,v,w
  double precision, intent(in) :: x,y,z
  logical, intent(in) :: labs
  double precision :: x0, y0, z0, x1, y1, z1, l, l_contrib, l_void_before
  double precision, dimension(NLTEspec%Nwaves) :: Snu, Snu_c
  double precision, dimension(NLTEspec%Nwaves) :: tau, tau_c, dtau_c, dtau, chiI
  integer :: nbr_cell, icell, next_cell, previous_cell, icell_star, i_star
  double precision :: facteur_tau
  logical :: lcellule_non_vide, lsubtract_avg, lintersect_stars, get_wlam = .false.

  x1=x;y1=y;z1=z
  x0=x;y0=y;z0=z
  next_cell = icell_in
  nbr_cell = 0

  tau = 0.0_dp
  tau_c = 0.0_dp


  NLTEspec%I(:,iray,id) = 0d0
  NLTEspec%Ic(:,iray,id) = 0d0
  NLTEspec%StokesV(:,iray,id) = 0d0
  NLTEspec%StokesQ(:,iray,id) = 0d0
  NLTEspec%StokesU(:,iray,id) = 0d0


  call intersect_stars(x,y,z, u,v,w, lintersect_stars, i_star, icell_star)

  infinie : do 
    icell = next_cell
    x0=x1 ; y0=y1 ; z0=z1

    if (icell <= n_cells) then
     lcellule_non_vide = atmos%lcompute_atomRT(icell)
    else
     lcellule_non_vide=.false.
    endif

    
    if (test_exit_grid(icell, x0, y0, z0)) RETURN
    if (lintersect_stars) then
      if (icell == icell_star) RETURN
    endif

    nbr_cell = nbr_cell + 1

    previous_cell = 0

    call cross_cell(x0,y0,z0, u,v,w,  icell, previous_cell, x1,y1,z1, next_cell, &
                     l, l_contrib, l_void_before)


   
    if (lcellule_non_vide) then
     lsubtract_avg = ((nbr_cell == 1).and.labs)
     l_contrib = l_contrib * AU_to_m
     if ((nbr_cell == 1).and.labs)  ds(iray,id) = l * AU_to_m

     CALL initAtomOpac(id)
     CALL NLTEopacity(id, icell, x0, y0, z0, x1, y1, z1, u, v, w, l, get_wlam)

     if (lstore_opac) then
      CALL BackgroundLines(id, icell, x0, y0, z0, x1, y1, z1, u, v, w, l)
      chiI = (NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id)+&
                    NLTEspec%AtomOpac%Kc(icell,:,1) + tiny_dp)
      dtau(:)   = l_contrib * chiI
      dtau_c(:) = l_contrib * NLTEspec%AtomOpac%Kc(icell,:,1)
      Snu = (NLTEspec%AtomOpac%jc(icell,:) + &
               NLTEspec%AtomOpac%eta_p(:,id) + NLTEspec%AtomOpac%eta(:,id) + &
                  NLTEspec%AtomOpac%Kc(icell,:,2) * NLTEspec%J(:,id)) / chiI

      Snu_c = (NLTEspec%AtomOpac%jc(icell,:) + &
            NLTEspec%AtomOpac%Kc(icell,:,2) * NLTEspec%Jc(:,id)) / &
            (NLTEspec%AtomOpac%Kc(icell,:,1) + tiny_dp)
     else
      CALL Background(id, icell, x0, y0, z0, x1, y1, z1, u, v, w, l)
      chiI = (NLTEspec%AtomOpac%chi_p(:,id)+NLTEspec%AtomOpac%chi(:,id) + tiny_dp)
      dtau(:)   =  l_contrib * chiI
      dtau_c(:) = l_contrib * NLTEspec%AtomOpac%chi_c(:,id)


      Snu = (NLTEspec%AtomOpac%eta_p(:,id) + NLTEspec%AtomOpac%eta(:,id) + &
                  NLTEspec%AtomOpac%sca_c(:,id) * NLTEspec%J(:,id)) / chiI


      Snu_c = (NLTEspec%AtomOpac%eta_c(:,id) + &
            NLTEspec%AtomOpac%sca_c(:,id) * NLTEspec%Jc(:,id)) / &
            (NLTEspec%AtomOpac%chi_c(:,id) + tiny_dp)
    end if
    !continuum not affected by polarisation yet
     NLTEspec%Ic(:,iray,id) = NLTEspec%Ic(:,iray,id) + &
                             exp(-tau_c) * (1.0_dp - exp(-dtau_c)) * Snu_c
                             
    !Correct line source fonction from polarisation
    !explicit product of Seff = S - (K/chiI - 1) * I
    !Is there a particular initialization to do for polarisation ?
    !because it will be zero at the first place
     Snu(:) = Snu(:) + &
     	-NLTEspec%AtomOpac%chiQUV_p(:,1,id) / chiI *  NLTEspec%StokesQ(:,iray,id) +&
     	-NLTEspec%AtomOpac%chiQUV_p(:,2,id) / chiI *  NLTEspec%StokesU(:,iray,id) +&
     	-NLTEspec%AtomOpac%chiQUV_p(:,3,id) / chiI *  NLTEspec%StokesV(:,iray,id)

     NLTEspec%I(:,iray,id) = NLTEspec%I(:,iray,id) + exp(-tau) * (1.0_dp - exp(-dtau)) * Snu
                             
     NLTEspec%StokesQ(:,iray,id) = NLTEspec%StokesQ(:,iray,id) + &
                             exp(-tau) * (1.0_dp - exp(-dtau)) * (&
			NLTEspec%AtomOpac%etaQUV_p(:,1,id) /chiI - &
			NLTEspec%AtomOpac%chiQUV_p(:,1,id) / chiI * NLTEspec%I(:,iray,id) - &
			NLTEspec%AtomOpac%rho_p(:,3,id)/chiI * NLTEspec%StokesU(:,iray,id) + &
			NLTEspec%AtomOpac%rho_p(:,2,id)/chiI * NLTEspec%StokesV(:,iray, id) &
     ) !end Snu_Q
     NLTEspec%StokesU(:,iray,id) = NLTEspec%StokesU(:,iray,id) + &
                             exp(-tau) * (1.0_dp - exp(-dtau)) * (&
			NLTEspec%AtomOpac%etaQUV_p(:,2,id) /chiI - &
			NLTEspec%AtomOpac%chiQUV_p(:,2,id) / chiI * NLTEspec%I(:,iray,id) + &
			NLTEspec%AtomOpac%rho_p(:,3,id)/chiI * NLTEspec%StokesQ(:,iray,id) - &
			NLTEspec%AtomOpac%rho_p(:,1,id)/chiI * NLTEspec%StokesV(:,iray, id) &
     ) !end Snu_U
     NLTEspec%StokesV(:,iray,id) = NLTEspec%StokesV(:,iray,id) + &
                             exp(-tau) * (1.0_dp - exp(-dtau)) * (&
			NLTEspec%AtomOpac%etaQUV_p(:,3,id) /chiI - &
			NLTEspec%AtomOpac%chiQUV_p(:,3,id) / chiI * NLTEspec%I(:,iray,id) - &
			NLTEspec%AtomOpac%rho_p(:,2,id)/chiI * NLTEspec%StokesQ(:,iray,id) + &
			NLTEspec%AtomOpac%rho_p(:,1,id)/chiI * NLTEspec%StokesU(:,iray, id) &
     ) !end Snu_V

     facteur_tau = 1.0

     tau = tau + dtau * facteur_tau
     tau_c = tau_c + dtau_c

    end if
  end do infinie
  ! -------------------------------------------------------------- !
  ! -------------------------------------------------------------- !
  RETURN
  END SUBROUTINE INTEG_RAY_LINE_Z
  
  SUBROUTINE FLUX_PIXEL_LINE(&
         id,ibin,iaz,n_iter_min,n_iter_max,ipix,jpix,pixelcorner,pixelsize,dx,dy,u,v,w)
  ! -------------------------------------------------------------- !
   ! Computes the flux emerging out of a pixel.
   ! see: mol_transfer.f90/intensite_pixel_mol()
  ! -------------------------------------------------------------- !

   integer, intent(in) :: ipix,jpix,id, n_iter_min, n_iter_max, ibin, iaz
   double precision, dimension(3), intent(in) :: pixelcorner,dx,dy
   double precision, intent(in) :: pixelsize,u,v,w
   integer, parameter :: maxSubPixels = 32
   double precision :: x0,y0,z0,u0,v0,w0
   double precision, dimension(NLTEspec%Nwaves) :: Iold, nu, I0, I0c
   double precision, dimension(3,NLTEspec%Nwaves) :: QUV
   double precision, dimension(3) :: sdx, sdy
   double precision:: npix2, diff
   double precision, parameter :: precision = 1.e-2
   integer :: i, j, subpixels, iray, ri, zj, phik, icell, iter
   logical :: lintersect, labs

   labs = .false.
   ! reset local Fluxes
   !I0c = 0d0
   !I0 = 0d0
   !if (atmos%magnetized .and. PRT_SOLUTION == "FULL_STOKES") QUV(:,:) = 0d0

   ! Ray tracing : on se propage dans l'autre sens
   u0 = -u ; v0 = -v ; w0 = -w

   ! le nbre de subpixel en x est 2^(iter-1)
   subpixels = 1
   iter = 1

   infinie : do ! Boucle infinie tant que le pixel n'est pas converge
     npix2 =  real(subpixels)**2
     Iold = I0
     I0 = 0d0
     I0c = 0d0
     if (atmos%magnetized.and. PRT_SOLUTION == "FULL_STOKES") QUV(:,:) = 0d0
     ! Vecteurs definissant les sous-pixels
     sdx(:) = dx(:) / real(subpixels,kind=dp)
     sdy(:) = dy(:) / real(subpixels,kind=dp)

     iray = 1 ! because the direction is fixed and we compute the flux emerging
               ! from a pixel, by computing the Intensity in this pixel

     ! L'obs est en dehors de la grille
     ri = 2*n_rad ; zj=1 ; phik=1

     ! Boucle sur les sous-pixels qui calcule l'intensite au centre
     ! de chaque sous pixel
     do i = 1,subpixels
        do j = 1,subpixels
           ! Centre du sous-pixel
           x0 = pixelcorner(1) + (i - 0.5_dp) * sdx(1) + (j-0.5_dp) * sdy(1)
           y0 = pixelcorner(2) + (i - 0.5_dp) * sdx(2) + (j-0.5_dp) * sdy(2)
           z0 = pixelcorner(3) + (i - 0.5_dp) * sdx(3) + (j-0.5_dp) * sdy(3)
           ! On se met au bord de la grille : propagation a l'envers
           !write(*,*) x0, y0, z0
           CALL move_to_grid(id, x0,y0,z0,u0,v0,w0, icell,lintersect)
           if (lintersect) then ! On rencontre la grille, on a potentiellement du flux
           !write(*,*) i, j, lintersect, labs, n_cells, icell
             CALL INTEG_RAY_LINE(id, icell, x0,y0,z0,u0,v0,w0,iray,labs)
             I0 = I0 + NLTEspec%I(:,iray,id)
             I0c = I0c + NLTEspec%Ic(:,iray,id)
             if (atmos%magnetized.and.PRT_SOLUTION == "FULL_STOKES") then
             	QUV(3,:) = QUV(3,:) + NLTEspec%STokesV(:,iray,id)
             	QUV(1,:) = QUV(1,:) + NLTEspec%STokesQ(:,iray,id)
             	QUV(2,:) = QUV(2,:) + NLTEspec%STokesU(:,iray,id)
             end if
           !else !Outside the grid, no radiation flux
           endif
        end do !j
     end do !i

     I0 = I0 / npix2
     I0c = I0c / npix2
     if (atmos%magnetized.and.PRT_SOLUTION == "FULL_STOKES") QUV(:,:) = QUV(:,:) / npix2

     if (iter < n_iter_min) then
        ! On itere par defaut
        subpixels = subpixels * 2
     else if (iter >= n_iter_max) then
        ! On arrete pour pas tourner dans le vide
        ! write(*,*) "Warning : converging pb in ray-tracing"
        ! write(*,*) " Pixel", ipix, jpix
        exit infinie
     else
        ! On fait le test sur a difference
        diff = maxval( abs(I0 - Iold) / (I0 + 1e-300_dp) )
        if (diff > precision ) then
           ! On est pas converge
           subpixels = subpixels * 2
        else
           exit infinie
        end if
     end if ! iter
     iter = iter + 1
   end do infinie

  !Prise en compte de la surface du pixel (en sr)

  nu = 1d0 !c_light / NLTEspec%lambda * 1d9 !to get W/m2 instead of W/m2/Hz !in Hz
  ! Flux out of a pixel in W/m2/Hz
  I0 = nu * I0 * (pixelsize / (distance*pc_to_AU) )**2
  I0c = nu * I0c * (pixelsize / (distance*pc_to_AU) )**2
  if (atmos%magnetized.and.PRT_SOLUTION == "FULL_STOKES") then 
   QUV(1,:) = QUV(1,:) * nu * (pixelsize / (distance*pc_to_AU) )**2
   QUV(2,:) = QUV(2,:) * nu * (pixelsize / (distance*pc_to_AU) )**2
   QUV(3,:) = QUV(3,:) * nu * (pixelsize / (distance*pc_to_AU) )**2
  end if

  ! adding to the total flux map.
  if (RT_line_method==1) then
    NLTEspec%Flux(:,1,1,ibin,iaz) = NLTEspec%Flux(:,1,1,ibin,iaz) + I0
    NLTEspec%Fluxc(:,1,1,ibin,iaz) = NLTEspec%Fluxc(:,1,1,ibin,iaz) + I0c
  else
    NLTEspec%Flux(:,ipix,jpix,ibin,iaz) = I0
    NLTEspec%Fluxc(:,ipix,jpix,ibin,iaz) = I0c
    if (atmos%magnetized.and.PRT_SOLUTION == "FULL_STOKES") then 
     NLTEspec%F_QUV(1,:,ipix,jpix,ibin,iaz) = QUV(1,:) !U
     NLTEspec%F_QUV(2,:,ipix,jpix,ibin,iaz) = QUV(2,:) !Q
     NLTEspec%F_QUV(3,:,ipix,jpix,ibin,iaz) = QUV(3,:) !V
    end if
  end if

  RETURN
  END SUBROUTINE FLUX_PIXEL_LINE

 SUBROUTINE EMISSION_LINE_MAP(ibin,iaz)
 ! -------------------------------------------------------------- !
  ! Line emission map in a given direction n(ibin,iaz),
  ! using ray-tracing.
  ! if only one pixel it gives the total Flux.
  ! See: emission_line_map in mol_transfer.f90
 ! -------------------------------------------------------------- !
  integer, intent(in) :: ibin, iaz !define the direction in which the map is computed
  double precision :: x0,y0,z0,l,u,v,w

  double precision, dimension(3) :: uvw, x_plan_image, x, y_plan_image, center, dx, dy, Icorner
  double precision, dimension(3,nb_proc) :: pixelcorner
  double precision:: taille_pix, nu
  integer :: i,j, id, npix_x_max, n_iter_min, n_iter_max

  integer, parameter :: n_rad_RT = 100, n_phi_RT = 36
  integer, parameter :: n_ray_star = 1000
  double precision, dimension(n_rad_RT) :: tab_r
  double precision:: rmin_RT, rmax_RT, fact_r, r, phi, fact_A, cst_phi
  integer :: ri_RT, phi_RT, lambda, lM, lR, lB, ll
  logical :: lresolved

  write(*,*) "incl (deg) = ", tab_RT_incl(ibin), "azimuth (deg) = ", tab_RT_az(iaz)

  u = tab_u_RT(ibin,iaz) ;  v = tab_v_RT(ibin,iaz) ;  w = tab_w_RT(ibin)
  uvw = (/u,v,w/) !vector position
  write(*,*) "u=", u*rad_to_deg, "v=",v*rad_to_deg, "w=",w*rad_to_deg

  ! Definition des vecteurs de base du plan image dans le repere universel
  ! Vecteur x image sans PA : il est dans le plan (x,y) et orthogonal a uvw
  x = (/cos(tab_RT_az(iaz) * deg_to_rad),sin(tab_RT_az(iaz) * deg_to_rad),0._dp/)

  ! Vecteur x image avec PA
  if (abs(ang_disque) > tiny_real) then
     ! Todo : on peut faire plus simple car axe rotation perpendiculaire a x
     x_plan_image = rotation_3d(uvw, ang_disque, x)
  else
     x_plan_image = x
  endif

  ! Vecteur y image avec PA : orthogonal a x_plan_image et uvw
  y_plan_image = -cross_product(x_plan_image, uvw)

  ! position initiale hors modele (du cote de l'observateur)
  ! = centre de l'image
  l = 10.*Rmax  ! on se met loin ! in AU

  x0 = u * l  ;  y0 = v * l  ;  z0 = w * l
  center(1) = x0 ; center(2) = y0 ; center(3) = z0

  ! Coin en bas gauche de l'image
  Icorner(:) = center(:) - 0.5 * map_size * (x_plan_image + y_plan_image)

  if (RT_line_method==1) then !log pixels
    n_iter_min = 1
    n_iter_max = 1

    ! dx and dy are only required for stellar map here
    taille_pix = (map_size/zoom)  ! en AU
    dx(:) = x_plan_image * taille_pix
    dy(:) = y_plan_image * taille_pix

    i = 1
    j = 1
    lresolved = .false.

    rmin_RT = max(w*0.9_dp,0.05_dp) * Rmin
    rmax_RT = 2.0_dp * Rmax

    tab_r(1) = rmin_RT
    fact_r = exp( (1.0_dp/(real(n_rad_RT,kind=dp) -1))*log(rmax_RT/rmin_RT) )

    do ri_RT = 2, n_rad_RT
      tab_r(ri_RT) = tab_r(ri_RT-1) * fact_r
    enddo

    fact_A = sqrt(pi * (fact_r - 1.0_dp/fact_r)  / n_phi_RT )

    ! Boucle sur les rayons d'echantillonnage
    !$omp parallel &
    !$omp default(none) &
    !$omp private(ri_RT,id,r,taille_pix,phi_RT,phi,pixelcorner) &
    !$omp shared(tab_r,fact_A,x_plan_image,y_plan_image,center,dx,dy,u,v,w,i,j) &
    !$omp shared(n_iter_min,n_iter_max,l_sym_ima,cst_phi,ibin,iaz)
    id =1 ! pour code sequentiel

    if (l_sym_ima) then
      cst_phi = pi  / real(n_phi_RT,kind=dp)
    else
      cst_phi = deux_pi  / real(n_phi_RT,kind=dp)
    endif

     !$omp do schedule(dynamic,1)
     do ri_RT=1, n_rad_RT
        !$ id = omp_get_thread_num() + 1

        r = tab_r(ri_RT)
        taille_pix =  fact_A * r ! racine carree de l'aire du pixel

        do phi_RT=1,n_phi_RT ! de 0 a pi
           phi = cst_phi * (real(phi_RT,kind=dp) -0.5_dp)
           pixelcorner(:,id) = center(:) + r * sin(phi) * x_plan_image + r * cos(phi) * y_plan_image
            ! C'est le centre en fait car dx = dy = 0.
           CALL FLUX_PIXEL_LINE(id,ibin,iaz,n_iter_min,n_iter_max, &
                      i,j,pixelcorner(:,id),taille_pix,dx,dy,u,v,w)
        end do !j
     end do !i
     !$omp end do
     !$omp end parallel
  else !method 2
     ! Vecteurs definissant les pixels (dx,dy) dans le repere universel
     taille_pix = (map_size/zoom) / real(max(npix_x,npix_y),kind=dp) ! en AU
     lresolved = .true.

     dx(:) = x_plan_image * taille_pix
     dy(:) = y_plan_image * taille_pix

     if (l_sym_ima) then
        npix_x_max = npix_x/2 + modulo(npix_x,2)
     else
        npix_x_max = npix_x
     endif

     !$omp parallel &
     !$omp default(none) &
     !$omp private(i,j,id) &
     !$omp shared(Icorner,pixelcorner,dx,dy,u,v,w,taille_pix,npix_x_max,npix_y) &
     !$omp shared(n_iter_min,n_iter_max,ibin,iaz)

     ! loop on pixels
     id = 1 ! pour code sequentiel
     n_iter_min = 1 ! 3
     n_iter_max = 1 ! 6

     !$omp do schedule(dynamic,1)
     do i = 1,npix_x_max
        !$ id = omp_get_thread_num() + 1
        do j = 1,npix_y
           ! Coin en bas gauche du pixel
           pixelcorner(:,id) = Icorner(:) + (i-1) * dx(:) + (j-1) * dy(:)
           CALL FLUX_PIXEL_LINE(id,ibin,iaz,n_iter_min,n_iter_max, &
                      i,j,pixelcorner(:,id),taille_pix,dx,dy,u,v,w)
        enddo !j
     enddo !i
     !$omp end do
     !$omp end parallel
  end if

  write(*,*) " -> Adding stellar flux"
  !! This is slow in my implementation actually
  do lambda = 1, NLTEspec%Nwaves
   nu = c_light / NLTEspec%lambda(lambda) * 1d9 !if NLTEspec%Flux in W/m2 set nu = 1d0 Hz
                                             !else it means that in FLUX_PIXEL_LINE, nu
                                             !is 1d0 (to have flux in W/m2/Hz)
   CALL compute_stars_map(lambda, u, v, w, taille_pix, dx, dy, lresolved)
   NLTEspec%Flux(lambda,:,:,ibin,iaz) =  NLTEspec%Flux(lambda,:,:,ibin,iaz) +  &
                                         stars_map(:,:,1) / nu
   NLTEspec%Fluxc(lambda,:,:,ibin,iaz) = NLTEspec%Fluxc(lambda,:,:,ibin,iaz) + &
                                         stars_map_cont(:,:,1) / nu
  end do

 RETURN
 END SUBROUTINE EMISSION_LINE_MAP

 SUBROUTINE Atomic_transfer()
 ! --------------------------------------------------------------------------- !
  ! This routine initialises the necessary quantities for atomic line transfer
  ! and calls the appropriate routines for LTE or NLTE transfer.
 ! --------------------------------------------------------------------------- !
  integer :: atomunit = 1, nact
  integer :: icell
  integer :: ibin, iaz, Nrayone = 1
  real(kind=dp) :: dumm
  character(len=20) :: ne_start_sol = "H_IONISATION"
  character(len=20)  :: newPRT_SOLUTION = "FULL_STOKES"
  logical :: lwrite_waves = .false.

 ! -------------------------------INITIALIZE AL-RT ------------------------------------ !
  Profile => IProfile
  INTEG_RAY_LINE => INTEG_RAY_LINE_I
  optical_length_tot => atom_optical_length_tot

  if (.not.associated(optical_length_tot)) then
   write(*,*) "pointer optical_length_tot not associated"
   stop
  end if

  if (npix_x_save > 1) then
   RT_line_method = 2 ! creation d'une carte avec pixels carres
   npix_x = npix_x_save ; npix_y = npix_y_save
  else
   RT_line_method = 1 !pixels circulaires
  end if

  if (PRT_SOLUTION == "FULL_STOKES") then
   CALL Warning(" Full Stokes solution not allowed. Stokes polarization not handled in SEE yet.")
   PRT_SOLUTION = "FIELD_FREE"
  end if

  if (atmos%magnetized .and. PRT_SOLUTION /= "NO_STOKES") then
   if (PRT_SOLUTION == "FIELD_FREE") newPRT_SOLUTION = "FULL_STOKES"
   CALL adjustStokesMode(PRT_SOLUTION)
  end if

  !read in dust_transfer.f90 in case of -pluto.
  !mainly because, RT atomic line and dust RT are not decoupled
  !move elsewhere, in the model reading/definition?
 ! ------------------------------------------------------------------------------------ !
 ! ------------------------------------------------------------------------------------ !
!! ----------------------- Read Model ---------------------- !!
  ! -> only for not Voronoi
  !later use the same density and T as defined in dust_transfer.f90
  !apply a correction for atomic line if needed.
  !if not flag atom in parafile, never enter this subroutine
  if (.not.lpluto_file) then 
   !CALL magneto_accretion_model()  
   CALL uniform_law_model()
  end if
!! --------------------------------------------------------- !!
 ! ------------------------------------------------------------------------------------ !
 ! ----------------------- READATOM and INITIZALIZE POPS ------------------------------ !

  !Read atomic models and allocate space for n, nstar, vbroad, ntotal
  ! on the whole grid space.
  CALL readAtomicModels(atomunit)
  if (atmos%NactiveAtoms > 0) then 
   atmos%Nrays = 20
   write(*,*) " Using", atmos%Nrays," rays for NLTE line transfer"
  end if

  ! if the electron density is not provided by the model or simply want to
  ! recompute it
  ! if atmos%ne given, but one want to recompute ne
  ! else atmos%ne not given, its computation is mandatory
  ! if NLTE pops are read in readAtomicModels, H%n(Nlevel,:) and atom%n
  !can be used for the electron density calculation.
  if (.not.atmos%calc_ne) atmos%calc_ne = lsolve_for_ne
  if (lsolve_for_ne) write(*,*) "(Force) Solving for electron density"
  if (atmos%calc_ne) then
   if (lsolve_for_ne) write(*,*) "(Force) Solving for electron density"
   if (.not.lsolve_for_ne) write(*,*) "Solving for electron density"
   write(*,*) " Starting solution : ", ne_start_sol
   if ((ne_start_sol == "NE_MODEL") .and. (atmos%calc_ne)) then
    write(*,*) "WARNING, ne from model is presumably 0 (or not given)."
    write(*,*) "Changing ne starting solution NE_MODEL in H_IONISATION"
    ne_start_sol = "H_IONISATION"
   end if
   CALL SolveElectronDensity(ne_start_sol)
   CALL writeElectron()
  end if
  CALL writeHydrogenDensity()
  CALL setLTEcoefficients () !write pops at the end because we probably have NLTE pops also
  !set Hydrogen%n = Hydrogen%nstar for the background opacities calculations.
 ! ------------------------------------------------------------------------------------ !
 ! ------------- INITIALIZE WAVELNGTH GRID AND BACKGROUND OPAC ------------------------ !
 ! ------------------------------------------------------------------------------------ !
  NLTEspec%atmos => atmos
  CALL initSpectrum(lam0=656.398393d0,vacuum_to_air=lvacuum_to_air,write_wavelength=lwrite_waves)
  CALL allocSpectrum()
  if (lstore_opac) then !o nly Background lines and active transitions
                                         ! chi and eta, are computed on the fly.
                                         ! Background continua (=ETL) are kept in memory.
   if (real(3*n_cells*NLTEspec%Nwaves)/(1024**3) < 1.) then
    write(*,*) "Keeping", real(3*n_cells*NLTEspec%Nwaves)/(1024**2), " MB of memory", &
   	 " for Background continuum opacities."
   else
    write(*,*) "Keeping", real(3*n_cells*NLTEspec%Nwaves)/(1024**3), " GB of memory", &
   	 " for Background continuum opacities."
   end if
   !!To DO: keep line LTE opacities if lstatic
   !$omp parallel &
   !$omp default(none) &
   !$omp private(icell) &
   !$omp shared(atmos)
   !$omp do
   do icell=1,atmos%Nspace
    CALL BackgroundContinua(icell)
   end do
   !$omp end do
   !$omp end parallel
   !!!TO DO:
   ! At the end of NLTE transfer keep active continua in memory for images
   !just like background conitua, avoiding te recompute them as they do not change
   !! TDO DO2: try to keep lines opac also.
  end if
 ! ------------------------------------------------------------------------------------ !
 ! --------------------- ADJUST MCFOST FOR STELLAR MAP AND VELOCITY ------------------- !
  ! ----- ALLOCATE SOME MCFOST'S INTRINSIC VARIABLES NEEDED FOR AL-RT ------!
  CALL reallocate_mcfost_vars()
  ! --- END ALLOCATING SOME MCFOST'S INTRINSIC VARIABLES NEEDED FOR AL-RT --!
 ! ------------------------------------------------------------------------------------ !
 ! ----------------------------------- NLTE LOOP -------------------------------------- !
  !The BIG PART IS HERE
  if (atmos%Nactiveatoms > 0) CALL NLTEloop()
  open(unit=12, file="Snu_nlte_conv.dat",status="unknown")
  icell = 1
  CALL initAtomOpac(1)
  CALL BackgroundLines(1,icell, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, dumm)
  CALL NLTEopacity(1, icell, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, 0d0, dumm, .false.)
  do nact=1, NLTEspec%Nwaves
  write(12,"(5E)") NLTEspec%lambda(nact), NLTEspec%AtomOpac%eta(nact,1), NLTEspec%AtomOpac%chi(nact, 1), &
    NLTEspec%AtomOpac%eta_p(nact,1)+NLTEspec%AtomOpac%jc(icell,nact), NLTEspec%AtomOpac%chi_p(nact,1)+NLTEspec%AtomOpac%Kc(icell,nact,1)
  end do
  close(12)
  stop
 ! ------------------------------------------------------------------------------------ !
 ! ------------------------------------------------------------------------------------ !
 ! ----------------------------------- MAKE IMAGES ------------------------------------ !
  if (atmos%Nrays /= Nrayone) CALL reallocate_rays_arrays(Nrayone)
  !Except except ds(Nray,Nproc) and Polarized arrays which are: 1) deallocated if PRT_SOL
  !is FIELD_FREE (or not allocated if no magnetic field), reallocated if FULL_STOKES.
  !And, atmos%Nrays = Nrayone if they are different.
  !This in order to reduce the memory of arrays in the map calculation
  if (atmos%magnetized .and. PRT_SOLUTION /= "NO_STOKES") then
   if (PRT_SOLUTION == "FIELD_FREE") PRT_SOLUTION = newPRT_SOLUTION
    CALL adjustStokesMode(PRT_SOLUTION)
  end if

  write(*,*) "Computing emission flux map..."
  !Use converged NLTEOpac
  do ibin=1,RT_n_incl
     do iaz=1,RT_n_az
       CALL EMISSION_LINE_MAP(ibin,iaz)
     end do
  end do
  CALL WRITE_FLUX()
 ! ------------------------------------------------------------------------------------ !
 ! ------------------------------------------------------------------------------------ !
 ! -------------------------------- CLEANING ------------------------------------------ !
 !close file after NLTE loop
!Temporary: because we kept in memory, so file is closed earlier
!  do nact=1,atmos%Nactiveatoms
!   CALL closeCollisionFile(atmos%ActiveAtoms(nact)%ptr_atom) !if opened
!  end do
 !CALL WRITEATOM() !keep C in memory for that ?
 CALL freeSpectrum() !deallocate spectral variables
 CALL free_atomic_atmos()
 NULLIFY(optical_length_tot, Profile)

 RETURN
 END SUBROUTINE
 ! ------------------------------------------------------------------------------------ !

 SUBROUTINE NLTEloop() !for all active atoms
 ! -------------------------------------------------------- !
  ! CASE : MALI
  ! CASE : HOGEREIJDE
  !      -> should be simpler (in reading and implementing)
  !			than MALI
  !		 -> less accurate than MALI
  !		 -> faster than MALI
  !		 -> should have a lower convergence speed ?
 ! -------------------------------------------------------- !
 
#include "sprng_f.h"

  integer, parameter :: n_rayons_start = 50 ! l'augmenter permet de reduire le tps de l'etape 2 qui est la plus longue
  integer, parameter :: n_rayons_start2 = 20
  integer, parameter :: n_iter2_max = 3
  integer :: n_rayons_max = 0!n_rayons_start2 * (2**(n_iter2_max-1))
  integer :: n_level_comp
  real, parameter :: precision_sub = 1.0e-3
  real, parameter :: precision = 1.0e-1
  integer :: etape, etape_start, etape_end, iray, n_rayons
  integer :: n_iter, n_iter_loc, id, i, iray_start, alloc_status
  integer, dimension(nb_proc) :: max_n_iter_loc

  logical :: lfixed_Rays, lnotfixed_Rays, lconverged, lconverged_loc, lprevious_converged

  real :: rand, rand2, rand3, fac_etape

  real(kind=dp) :: x0, y0, z0, u0, v0, w0, w02, srw02, argmt, diff, maxdiff, norme, dN
  double precision :: l_dum, l_c_dum, l_v_dum, x1, x2, x3
  integer 		   :: n_c_dum

  logical :: labs
  integer :: atomunit = 1, nact
  integer :: icell
  integer :: Nlevel_total = 0, NmaxLevel
  character(len=20) :: ne_start_sol = "NE_MODEL" !iterate from the starting guess
  character(len=20) :: Methode
  double precision, allocatable, dimension(:,:,:) :: pop_old, pop

  Methode = "MALI"
  write(*,*) "   -> Solving for kinetic equations for ", atmos%Nactiveatoms, " atoms"


  if (allocated(ds)) deallocate(ds)
  allocate(ds(atmos%Nrays,NLTEspec%NPROC))
  ds = 0d0 !meters
  
  n_rayons_max = atmos%Nrays
  labs = .true. !to have ds
  id = 1
  
 ! ----------------------------  INITIAL POPS------------------------------------------ !
  ! CALL initialSol()
  ! if OLD_POPULATIONS, the init is done at the reading
  ! for now initialSol() is replaced by this if loop on active atoms
  NmaxLevel = 0
  do nact=1,atmos%Nactiveatoms
     !Now we can set it to .true. The new background pops or the new ne pops
     !will used the H%n
     atmos%ActiveAtoms(nact)%ptr_atom%NLTEpops = .true.
     Nlevel_total = Nlevel_total + atmos%ActiveAtoms(nact)%ptr_atom%Nlevel**2
     NmaxLevel = max(NmaxLevel, atmos%ActiveAtoms(nact)%ptr_atom%Nlevel)
     write(*,*) "Setting initial solution for active atom ", atmos%ActiveAtoms(nact)%ptr_atom%ID, &
      atmos%ActiveAtoms(nact)%ptr_atom%active
     atmos%ActiveAtoms(nact)%ptr_atom%n = 1d0 * atmos%ActiveAtoms(nact)%ptr_atom%nstar
     !CALL allocNetCoolingRates(atmos%ActiveAtoms(nact)%ptr_atom)
  end do
  
  ! Temporary keep collision on RAM, BEWARE IT CAN BE LARGE, need a better collision routine
  ! which stores the required data to compute on the fly the Cij, instead of reading it
  ! each cell
   if (real(Nlevel_total*n_cells)/(1024**3) < 1.) then
    write(*,*) "Keeping", real(Nlevel_total*n_cells)/(1024**2), " MB of memory", &
   	 " for Collisional matrix."
   else
    write(*,*) "Keeping", real(Nlevel_total*n_cells)/(1024**3), " GB of memory", &
   	 " for Collisional matrix."
   end if

   do nact=1,atmos%Nactiveatoms
     allocate(atmos%ActiveAtoms(nact)%ptr_atom%ndag(atmos%ActiveAtoms(nact)%ptr_atom%Nlevel, n_cells))
     atmos%ActiveAtoms(nact)%ptr_atom%ndag = 0d0
     do icell=1,atmos%Nspace
	     CALL CollisionRate(icell, atmos%ActiveAtoms(nact)%ptr_atom) !open and allocated in LTE.f90
      !try keeping in memory until better collision routine !
  	end do
  	CALL closeCollisionFile(atmos%ActiveAtoms(nact)%ptr_atom) !if opened
  	deallocate(atmos%ActiveAtoms(nact)%ptr_atom%C) !not used anymore if stored on RAM
  end do
  !end replacing initSol()
  allocate(pop_old(atmos%NactiveAtoms, NmaxLevel, NLTEspec%NPROC)); pop_old = 0d0
          
  SELECT CASE (Methode)
   CASE ("MALI")
   
   		lfixed_rays = .true.
  		n_rayons = n_rayons_max
  		iray_start = 1
  		lprevious_converged = .false.
  		lnotfixed_rays = .not.lfixed_rays
  		lconverged = .false.
  		n_iter = 0
        CALL alloc_wlambda() !only for lines actually
 ! ---------------------------------- CELLS LOOP -------------------------------------- !
 		! Start loop here !
		!make sure to properly RETURN if NmaxIter=0
        !could be error in H background if not lstore_opac, cause opacities will be updated
       !but we do not want that
        do while (.not.lconverged) 
        	n_iter = n_iter + 1
        	max_n_iter_loc = 0
            write(*,*) " -> Iteration #", n_iter
 			!$omp parallel &
            !$omp default(none) &
            !$omp private(id,iray,rand,rand2,rand3,x0,y0,z0,u0,v0,w0,w02,srw02) &
            !$omp private(argmt,n_iter_loc,lconverged_loc,diff,norme,icell, dN) &
            !$omp shared(stream,n_rayons,iray_start, r_grid, z_grid) &
            !$omp shared(atmos, n_cells, pop_old, n_rayons_max) &
            !$omp shared(NLTEspec, lfixed_Rays,lnotfixed_Rays,labs,max_n_iter_loc)
            !$omp do schedule(static,1)
  			do icell=1, n_cells

   				CALL initGamma(icell)

   				!$ id = omp_get_thread_num() + 1
!   ! Read collisional data and fill collisional matrix C(Nlevel**2) for each ACTIVE atoms.
!   ! Initialize at C=0.0 for each cell points.
!   ! the matrix is allocated for ACTIVE atoms only in setLTEcoefficients and the file open
!   ! before the transfer starts and closed at the end. This is because we compute C at each cell
!   ! instead of the whole grid. So some extra IO overheads.
!   !They can be removed by keeping C in memory for each atom: NactAtom * Nlevel**2 * n_cells
!   ! Or keeping in memory the collision data. (TO DO)
!   	do nact=1,atmos%Nactiveatoms
! 	     CALL CollisionRate(icell, atmos%ActiveAtoms(nact)%ptr_atom)
!       !note that when updating populations, if ne is kept fixed (and T and nHtot etc)
!       !atom%C is fixed, therefore we only use initGamma. If they chane, call CollisionRate() again
!   	end do
    !Formal solution for this cell, for all wavelength and angle
   				if (atmos%lcompute_atomRT(icell)) then

     				do iray=iray_start, max(2,n_rayons_max)!two rays minimum
      
      					x0 = r_grid(icell)
      					y0 = 0d0
      					z0 = z_grid(icell)
      					!Assume no keplerian
      
     					norme = dsqrt(x0**2 + y0**2 + z0**2)
      					if (iray<max(2,n_rayons_max)/2+1) then
      						u0 = x0/norme
       						v0 = y0/norme
       						w0 = z0/norme
      					else
       						u0 = -x0/norme
       						v0 = -y0/norme
       						w0 = -z0/norme
      					end if

      !Only compute continuum NLTE for iray==1, because indpendent of direction
      !NLTEspec%AtomOpac%initialized(id) = (iray==1)
      !-> cannot do that because, icell changes during the propagation of the ray
      !so compute them for all cells, at each iteration, otherwise on the fly
      
      !Solve radiative transfer equation and compute Psi operator for the cell icell
      					CALL INTEG_RAY_LINE(id, icell, x0, y0, z0, u0, v0, w0, iray, labs)
      !compute cross-coupling terms for this cell and ray
      !comment to set to zero
       					CALL initCrossCoupling(id)
       					CALL fillCrossCoupling_terms(id, icell)
      !Fill gamma matrix and performs wavelength and direction integration
      					CALL fillGamma_OF(id,icell,iray,n_rayons)
     				end do !ray
!       					CALL initCrossCoupling(id)
!       					CALL fillCrossCoupling_terms(id, icell)
!       				CALL Gamma_LTE(id,icell)
					!CALL fillGamma(id, icell, n_rayons)
    
    !Once gamma is filled (angle and wavelength integration)
    !update the populations for each atom by Solving the SEE
                    do nact=1,atmos%Nactiveatoms
                     pop_old(nact, 1:atmos%ActiveAtoms(nact)%ptr_atom%Nlevel, id) = &
                      atmos%ActiveAtoms(nact)%ptr_atom%n(:,icell)
                     atmos%ActiveAtoms(nact)%ptr_atom%ndag(:,icell) = &
                     	atmos%ActiveAtoms(nact)%ptr_atom%n(:,icell)
                    end do
     				CALL updatePopulations(id, icell)

   				end if
  			end do !cell loop
  			!$omp end do
  			!$omp end parallel
  			cell_loop : do icell=1, atmos%Nspace
  			  	diff = 0d0
  				if (atmos%lcompute_atomRT(icell)) then
     				do nact=1,atmos%NactiveAtoms
     				    dN = abs(maxval(atmos%ActiveAtoms(nact)%ptr_atom%ndag(:,icell))-&
     				    		maxval(atmos%ActiveAtoms(nact)%ptr_atom%n(:,icell)))/&
     				    	maxval(atmos%ActiveAtoms(nact)%ptr_atom%ndag(:,icell))
     				    diff = max(diff, dN)
     					if (diff > 1d0) &
     						write(*,*) " ->", atmos%ActiveAtoms(nact)%ptr_atom%ID, " dpops = ", dN, diff
     					if (diff < precision) CYCLE cell_loop
     				end do
     			end if
     		end do cell_loop
  			if (n_iter >= 10) exit
 		end do !loop over iteration, convergence global
 
    CASE ("HOGEREIJDE")
  
  		!only etape1 for now
  		lfixed_rays = .true.
  		n_rayons = 2 ! one up one down
  		iray_start = 1
  		lprevious_converged = .false.
  		lnotfixed_rays = .not.lfixed_rays
  		lconverged = .false.
  		n_iter = 0 
  		

  		allocate(pop(atmos%NactiveAtoms, NmaxLevel, NLTEspec%NPROC)); pop = 0d0

        do while (.not.lconverged)
  			if (lfixed_rays) then
    			stream = 0.0
    			do i=1,nb_proc
     				stream(i) = init_sprng(gtype, i-1,nb_proc,seed,SPRNG_DEFAULT)
    			end do
 			 end if
        	n_iter = n_iter + 1
        	max_n_iter_loc = 0

            write(*,*) " -> Iteration #", n_iter
 			!$omp parallel &
            !$omp default(none) &
            !$omp private(id,iray,rand,rand2,rand3,x0,y0,z0,u0,v0,w0,w02,srw02) &
            !$omp private(argmt,n_iter_loc,lconverged_loc,diff,norme,icell, dN) &
			!$omp private(n_c_dum, l_dum, l_v_dum, l_c_dum, x1,x2,x3) &
            !$omp shared(stream,n_rayons,iray_start, r_grid, z_grid) &
            !$omp shared(atmos, n_cells, pop_old, pop) &
            !$omp shared(NLTEspec, lfixed_Rays,lnotfixed_Rays,labs,max_n_iter_loc)
            !$omp do schedule(static,1)
  			do icell=1, n_cells
   				!$ id = omp_get_thread_num() + 1
   				if (atmos%lcompute_atomRT(icell)) then
     				do iray=iray_start, iray_start-1+n_rayons
      
      					x0 = r_grid(icell)
      					y0 = 0d0
      					z0 = z_grid(icell)
      					!Assume no keplerian
      
     					 norme = dsqrt(x0**2 + y0**2 + z0**2)
      					if (iray==1) then
      						u0 = x0/norme
       						v0 = y0/norme
       						w0 = z0/norme
      					else
       						u0 = -x0/norme
       						v0 = -y0/norme
       						w0 = -z0/norme
      					end if
      
      					CALL INTEG_RAY_LINE(id, icell, x0, y0, z0, u0, v0, w0, iray, labs) 	
      				end do !iray		 
     				n_iter_loc = 0
    				lconverged_loc = .false.
    				do nact=1,atmos%NactiveAtoms
    				 pop(nact,1:atmos%ActiveAtoms(nact)%ptr_atom%Nlevel,id) = &
    				  atmos%ActiveAtoms(nact)%ptr_atom%n(:,icell)
    				end do
     				!sub iteration on the local emissivity, keeping I fixed
     				do while (.not.lconverged_loc)
       					n_iter_loc = n_iter_loc + 1
      
                        pop_old(:,:,id) = pop(:,:,id)
                        !calc J
						!stat equil for all atoms
						
     					diff = 0d0
     					do nact=1,atmos%NactiveAtoms
     				    	dN = abs(maxval(pop_old(nact,1:atmos%ActiveAtoms(nact)%ptr_atom%Nlevel,id)-&
     				    		atmos%ActiveAtoms(nact)%ptr_atom%n(:,icell)))
     				    	diff = max(diff, dN)
     						write(*,*) " ->", atmos%ActiveAtoms(nact)%ptr_atom%ID, " dpops = ", dN
     						pop(nact,1:atmos%ActiveAtoms(nact)%ptr_atom%Nlevel,id) = atmos%ActiveAtoms(nact)%ptr_atom%n(:,icell)			
     					end do				

       					if (diff < precision_sub) then
       						lconverged_loc = .true.
       					else
        					!recompute opacity of this cell., but I need angles and pos...
       						!
       						CALL cross_cell(x0,y0,z0, u0,v0,w0, icell, &
       						n_c_dum, x1,x2,x3, n_c_dum, l_dum, l_c_dum, l_v_dum)
       						NLTEspec%AtomOpac%chi(:,id) = 0d0
       						NLTEspec%AtomOpac%eta(:,id) = 0d0
       						!NOTE Zeeman opacities are not re set to zero and are accumulated
       						!change that or always use FIELD_FREE
       						CALL NLTEOpacity(id, icell, x0, y0, z0, x1, x2, x3, u0, v0, w0, l_dum, .false.)
       					end if
     				end do
     	            if (n_iter_loc > max_n_iter_loc(id)) max_n_iter_loc(id) = n_iter_loc
     			end if !lcompute_atomRT
     		end do !icell
        	!$omp end do
        	!$omp end parallel
        	
        	!Global convergence critrium
!         maxdiff = 0.0
!         do icell = 1, n_cells
!            if (lcompute_molRT(icell)) then
!               diff = maxval( abs( tab_nLevel(icell,1:n_level_comp) - tab_nLevel_old(icell,1:n_level_comp) ) / &
!                    tab_nLevel_old(icell,1:n_level_comp) + 1e-300_dp)
!               if (diff > maxdiff) maxdiff = diff
!            endif
!         enddo ! icell
! 
!         write(*,*) maxval(max_n_iter_loc), "sub-iterations"
!         write(*,*) "Relative difference =", real(maxdiff)
!         write(*,*) "Threshold =", precision*fac_etape
! 
!         if (maxdiff < precision*fac_etape) then
!            if (lprevious_converged) then
!               lconverged = .true.
!            else
!               lprevious_converged = .true.
!            endif
!         else
!            lprevious_converged = .false.
!            if (.not.lfixed_rays) then
!               n_rayons = n_rayons * 2
!              ! if (n_rayons > n_rayons_max) then
!               if (n_iter >= n_iter2_max) then
!               write(*,*) "Warning : not enough rays to converge !!"
!                  lconverged = .true.
!               endif
! 
!               ! On continue en calculant 2 fois plus de rayons
!               ! On les ajoute a l'ensemble de ceux calcules precedemment
! !              iray_start = iray_start + n_rayons
! 
!            endif
!         endif
! 
!         write(*,*) "STAT", minval(tab_nLevel(:,1:n_level_comp)), maxval(tab_nLevel(:,1:n_level_comp))
  		end do !while
  CASE DEFAULT
   CALL ERROR("Methode for SEE unknown", methode)
  END SELECT
 ! -------------------------------- CLEANING ------------------------------------------ !
  ! Remove NLTE quantities not useful now
  deallocate(pop_old)
  if (allocated(pop)) deallocate(pop)
  do nact=1,atmos%Nactiveatoms
   if (allocated(atmos%ActiveAtoms(nact)%ptr_atom%gamma)) & !otherwise we have never enter the loop
     deallocate(atmos%ActiveAtoms(nact)%ptr_atom%gamma)
   deallocate(atmos%ActiveAtoms(nact)%ptr_atom%Ckij)
   deallocate(atmos%ActiveAtoms(nact)%ptr_atom%ndag)
  end do
  deallocate(ds)
 ! ------------------------------------------------------------------------------------ !
 RETURN
 END SUBROUTINE NLTEloop
 ! ------------------------------------------------------------------------------------ !
 
 SUBROUTINE adjustStokesMode(Solution)
 !
 !
   character(len=*), intent(in) :: Solution
   
!     if (.not.atmos%magnetized) then
!      Profile => IProfile
!      RETURN
!     end if
      
    if (SOLUTION=="FIELD_FREE") then
      !if (associated(Profile)) Profile => NULL()
      !Profile => Iprofile !already init to that
      if (allocated(NLTEspec%AtomOpac%rho_p)) deallocate(NLTEspec%AtomOpac%rho_p)
      if (allocated(NLTEspec%AtomOpac%etaQUV_p)) deallocate(NLTEspec%AtomOpac%etaQUV_p)
      if (allocated(NLTEspec%AtomOpac%chiQUV_p)) deallocate(NLTEspec%AtomOpac%chiQUV_p)
      if (allocated(NLTEspec%F_QUV)) deallocate(NLTEspec%F_QUV)
      if (allocated(NLTEspec%StokesV)) deallocate(NLTEspec%StokesV, NLTEspec%StokesQ, &
      												NLTEspec%StokesU)
      write(*,*) " Using FIELD_FREE solution for the SEE!"
      CALL Warning("  Set PRT_SOLUTION to FULL_STOKES for images")
      
    else if (SOLUTION=="POLARIZATION_FREE") then
     CALL ERROR("POLARIZATION_FREE solution not implemented yet")
     !NLTE not implemented in integ_ray_line_z and Zprofile always compute the full
     !propagation dispersion matrix, but only the first row is needed
     if (associated(Profile)) Profile => NULL()
     Profile => Zprofile
     if (associated(INTEG_RAY_LINE)) INTEG_RAY_LINE => NULL()
     INTEG_RAY_LINE => INTEG_RAY_LINE_Z
     
     !beware, only I! polarization is neglected hence not allocated
      if (.not.allocated(NLTEspec%AtomOpac%rho_p)) then !same for all, dangerous.
      	allocate(NLTEspec%AtomOpac%rho_p(NLTEspec%Nwaves, 3, NLTEspec%NPROC))
        allocate(NLTEspec%AtomOpac%etaQUV_p(NLTEspec%Nwaves, 3, NLTEspec%NPROC))
        allocate(NLTEspec%AtomOpac%chiQUV_p(NLTEspec%Nwaves, 3, NLTEspec%NPROC))

        write(*,*) " Using POLARIZATION_FREE solution for the SEE!"
     end if
							
    else if (SOLUTION=="FULL_STOKES") then !Solution unchanged here
      if (associated(Profile)) Profile => NULL()
      Profile => Zprofile
      if (associated(INTEG_RAY_LINE)) INTEG_RAY_LINE => NULL()
      INTEG_RAY_LINE => INTEG_RAY_LINE_Z
      !allocate space for Zeeman polarisation
      !only LTE for now
       if (.not.allocated(NLTEspec%StokesQ)) & !all allocated, but dangerous ?
            allocate(NLTEspec%StokesQ(NLTEspec%NWAVES, atmos%NRAYS,NLTEspec%NPROC), & 
             NLTEspec%StokesU(NLTEspec%NWAVES, atmos%NRAYS,NLTEspec%NPROC), &
             NLTEspec%StokesV(NLTEspec%NWAVES, atmos%NRAYS,NLTEspec%NPROC))!, &
             !!NLTEspec%S_QUV(3,NLTEspec%Nwaves))
      NLTEspec%StokesQ=0d0
      NLTEspec%StokesU=0d0
      NLTEspec%StokesV=0d0
      if (.not.allocated(NLTEspec%F_QUV)) &
      	allocate(NLTEspec%F_QUV(3,NLTEspec%Nwaves,NPIX_X,NPIX_Y,RT_N_INCL,RT_N_AZ))
      NLTEspec%F_QUV = 0d0
      if (.not.allocated(NLTEspec%AtomOpac%rho_p)) then !same for all, dangerous.
      	allocate(NLTEspec%AtomOpac%rho_p(NLTEspec%Nwaves, 3, NLTEspec%NPROC))
        allocate(NLTEspec%AtomOpac%etaQUV_p(NLTEspec%Nwaves, 3, NLTEspec%NPROC))
        allocate(NLTEspec%AtomOpac%chiQUV_p(NLTEspec%Nwaves, 3, NLTEspec%NPROC))

        write(*,*) " Using FULL_STOKES solution for the SEE!"
      end if
    else
     CALL ERROR("Error in adjust StokesMode with solution=",Solution)
    end if
 RETURN
 END SUBROUTINE adjustStokesMode
 ! ------------------------------------------------------------------------------------ !

 SUBROUTINE reallocate_mcfost_vars()
  !--> should move them to init_atomic_atmos ? or elsewhere
  !need to be deallocated at the end of molecule RT or its okey ?`
  integer :: la
  CALL init_directions_ray_tracing()
  if (.not.allocated(stars_map)) allocate(stars_map(npix_x,npix_y,3))
  if (.not.allocated(stars_map_cont)) allocate(stars_map_cont(npix_x,npix_y,3))
  n_lambda = NLTEspec%Nwaves
  if (allocated(tab_lambda)) deallocate(tab_lambda)
  allocate(tab_lambda(n_lambda))
  if (allocated(tab_delta_lambda)) deallocate(tab_delta_lambda)
  allocate(tab_delta_lambda(n_lambda))
  tab_lambda = NLTEspec%lambda / MICRON_TO_NM
  tab_delta_lambda(1) = 0d0
  do la=2,NLTEspec%Nwaves
   tab_delta_lambda(la) = tab_lambda(la) - tab_lambda(la-1)
  end do
  if (allocated(tab_lambda_inf)) deallocate(tab_lambda_inf)
  allocate(tab_lambda_inf(n_lambda))
  if (allocated(tab_lambda_sup)) deallocate(tab_lambda_sup)
  allocate(tab_lambda_sup(n_lambda))
  tab_lambda_inf = tab_lambda
  tab_lambda_sup = tab_lambda_inf + tab_delta_lambda
  ! computes stellar flux at the new wavelength points
  CALL deallocate_stellar_spectra()
  ! probably do not deallocate, 'cause maybe dust is in here too.
  if (allocated(kappa)) deallocate(kappa) !do not use it anymore
  !used for star map ray-tracing.
  CALL allocate_stellar_spectra(n_lambda)
  CALL repartition_energie_etoiles()
  !If Vfield is used in atomic line transfer, with lkep or linfall
  !atmos%Vxyz is not used and lmagnetoaccr is supposed to be zero
  !and Vfield allocated and filled in the model definition if not previously allocated
  !nor filled.
  if (allocated(Vfield).and.lkeplerian.or.linfall) then
    write(*,*) "Vfield max/min", maxval(Vfield), minval(Vfield)
  else if (allocated(Vfield).and.lmagnetoaccr) then
   write(*,*) "deallocating Vfield for atomic lines when lmagnetoaccr = .true."
   deallocate(Vfield)
  end if

 RETURN
 END SUBROUTINE reallocate_mcfost_vars

END MODULE AtomicTransfer

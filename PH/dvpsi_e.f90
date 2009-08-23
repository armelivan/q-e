!
! Copyright (C) 2001-2008 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!----------------------------------------------------------------------
subroutine dvpsi_e (ik, ipol)
  !----------------------------------------------------------------------
  !
  ! On output: dvpsi contains P_c^+ x | psi_ik > in crystal axis 
  !            (projected on at(*,ipol) )
  !
  ! dvpsi is READ from file if this_pcxpsi_is_on_file(ik,ipol)=.true. 
  ! otherwise dvpsi is COMPUTED and WRITTEN on file (vkb,evc,igk must be set)
  !
  USE kinds,           ONLY : DP
  USE cell_base,       ONLY : tpiba, at
  USE ions_base,       ONLY : nat, ityp, ntyp => nsp
  USE io_global,       ONLY : stdout
  USE klist,           ONLY : xk
  USE gvect,           ONLY : g
  USE wvfct,           ONLY : npw, npwx, nbnd, igk, g2kin, et
  USE wavefunctions_module, ONLY: evc
  USE lsda_mod,        ONLY : current_spin, nspin
  USE spin_orb,        ONLY : lspinorb
  USE noncollin_module,ONLY : noncolin, npol
  USE becmod,          ONLY : becp, becp_nc, calbec
  USE uspp,            ONLY : okvan, nkb, vkb
  USE uspp_param,      ONLY : nh, nhm
  USE ramanm,          ONLY : eth_rps
  USE eqv,             ONLY : dpsi, dvpsi, eprec
  USE phus,            ONLY : becp1, becp1_nc
  USE qpoint,          ONLY : npwq, nksq
  USE units_ph,        ONLY : this_pcxpsi_is_on_file, lrcom, iucom, &
                              lrebar, iuebar
  USE control_ph,      ONLY : nbnd_occ

  implicit none
  !
  integer, intent(IN) :: ipol, ik
  !
  ! Local variables
  !
  integer :: ig, na, ibnd, jbnd, ikb, jkb, nt, lter, ih, jh, ijkb0,  &
             nrec, is, js, ijs
  ! counters

  real(DP), allocatable  :: gk (:,:), h_diag (:,:)
  ! the derivative of |k+G|
  real(DP) ::   anorm, thresh
  ! preconditioning cut-off
  ! the desired convergence of linter

  logical :: conv_root
  ! true if convergence has been achieved

  complex(DP), allocatable :: ps2(:,:,:), dvkb (:,:), dvkb1 (:,:),  &
       work (:,:), becp2(:,:), becp2_nc(:,:,:), spsi(:,:),  &
       psc(:,:,:,:), aux(:), deff_nc(:,:,:,:)
  REAL(DP), allocatable :: deff(:,:,:)
  complex(DP), external :: zdotc
  ! the scalar products
  external ch_psi_all, cg_psi
  !
  !
  call start_clock ('dvpsi_e')
  dpsi=(0.d0, 0.d0)
  dvpsi=(0.d0, 0.d0)
  if (this_pcxpsi_is_on_file(ik,ipol)) then
     nrec = (ipol - 1)*nksq + ik
     call davcio(dvpsi, lrebar, iuebar, nrec, -1)
     call stop_clock ('dvpsi_e')
     return
  end if
  !
  allocate (aux ( npwx*npol ))
  allocate (gk ( 3, npwx))    
  allocate (h_diag( npwx*npol, nbnd))    
  do ig = 1, npw
     gk (1, ig) = (xk (1, ik) + g (1, igk (ig) ) ) * tpiba
     gk (2, ig) = (xk (2, ik) + g (2, igk (ig) ) ) * tpiba
     gk (3, ig) = (xk (3, ik) + g (3, igk (ig) ) ) * tpiba
     g2kin (ig) = gk (1, ig) **2 + gk (2, ig) **2 + gk (3, ig) **2
  enddo
  !
  ! this is  the kinetic contribution to [H,x]:  -2i (k+G)_ipol * psi
  !
  do ibnd = 1, nbnd_occ (ik)
     do ig = 1, npw
        dpsi (ig, ibnd) = (at(1, ipol) * gk(1, ig) + &
             at(2, ipol) * gk(2, ig) + &
             at(3, ipol) * gk(3, ig) ) &
             *(0.d0,-2.d0)*evc (ig, ibnd)
     enddo
     IF (noncolin) THEN
        do ig = 1, npw
           dpsi (ig+npwx, ibnd) = (at(1, ipol) * gk(1, ig) + &
                at(2, ipol) * gk(2, ig) + &
                at(3, ipol) * gk(3, ig) ) &
                 *(0.d0,-2.d0)*evc (ig+npwx, ibnd)
        end do
     END IF
  enddo
!
! Uncomment this goto and the continue below to calculate 
! the matrix elements of p without the commutator with the
! nonlocal potential.
!
!  goto 111
  !
  ! and this is the contribution from nonlocal pseudopotentials
  !
  if (nkb == 0) go to 111
  !
  allocate (work ( npwx, nkb) )
  IF (noncolin) THEN
     allocate (becp2_nc (nkb, npol, nbnd))
     allocate (deff_nc (nhm, nhm, nat, nspin))
  ELSE
     allocate (becp2 (nkb, nbnd))
      allocate (deff (nhm, nhm, nat ))
  END IF
  allocate (dvkb (npwx, nkb), dvkb1(npwx, nkb))
  dvkb (:,:) = (0.d0, 0.d0)
  dvkb1(:,:) = (0.d0, 0.d0)
 
  call gen_us_dj (ik, dvkb)
  call gen_us_dy (ik, at (1, ipol), dvkb1)
  do ig = 1, npw
     if (g2kin (ig) < 1.0d-10) then
        gk (1, ig) = 0.d0
        gk (2, ig) = 0.d0
        gk (3, ig) = 0.d0
     else
        gk (1, ig) = gk (1, ig) / sqrt (g2kin (ig) )
        gk (2, ig) = gk (2, ig) / sqrt (g2kin (ig) )
        gk (3, ig) = gk (3, ig) / sqrt (g2kin (ig) )
     endif
  enddo

  jkb = 0
  work=(0.d0,0.d0)
  do nt = 1, ntyp
     do na = 1, nat
        if (nt == ityp (na)) then
           do ikb = 1, nh (nt)
              jkb = jkb + 1
              do ig = 1, npw
                 work (ig,jkb) = dvkb1 (ig, jkb) + dvkb (ig, jkb) * &
                      (at (1, ipol) * gk (1, ig) + &
                       at (2, ipol) * gk (2, ig) + &
                       at (3, ipol) * gk (3, ig) )
              enddo
           enddo
        endif
     enddo
  enddo
  deallocate (gk)

  IF ( noncolin ) THEN 
     call calbec (npw, work, evc, becp2_nc)
  ELSE
     call calbec (npw, work, evc, becp2)
  END IF

  IF (noncolin) THEN
     allocate (psc ( nkb, npol, nbnd, 2))
     psc=(0.d0,0.d0)
  ELSE
     allocate (ps2 ( nkb, nbnd, 2))
     ps2=(0.d0,0.d0)
  END IF
  DO ibnd = 1, nbnd_occ (ik)
     IF (noncolin) THEN
        CALL compute_deff_nc(deff_nc,et(ibnd,ik))
     ELSE
        CALL compute_deff(deff,et(ibnd,ik))
     ENDIF
     ijkb0 = 0
     do nt = 1, ntyp
        do na = 1, nat
           if (nt == ityp (na)) then
              do ih = 1, nh (nt)
                 ikb = ijkb0 + ih
                 do jh = 1, nh (nt)
                    jkb = ijkb0 + jh
                    IF (noncolin) THEN
                       ijs=0
                       DO is=1, npol
                          DO js = 1, npol
                             ijs=ijs+1
                             psc(ikb,is,ibnd,1)=psc(ikb,is,ibnd,1)+  &
                                       (0.d0,-1.d0)*    &
                                  becp2_nc(jkb,js,ibnd)*deff_nc(ih,jh,na,ijs) 
                             psc(ikb,is,ibnd,2)=psc(ikb,is,ibnd,2)+ &
                                     (0.d0,-1.d0)* &
                                 becp1_nc(jkb,js,ibnd,ik)*deff_nc(ih,jh,na,ijs) 
                          END DO
                       END DO
                    ELSE
                       ps2(ikb,ibnd,1) = ps2(ikb,ibnd,1) + becp2(jkb,ibnd) * &
                            (0.d0,-1.d0) * deff(ih,jh,na) 
                       ps2(ikb,ibnd,2) = ps2(ikb,ibnd,2) + becp1(jkb,ibnd,ik)* &
                            (0.d0,-1.d0)*deff(ih,jh,na)
                    END IF
                 enddo
              enddo
              ijkb0=ijkb0+nh(nt)
           end if
        enddo  ! na
     end do  ! nt
  end do ! nbnd
  if (ikb /= nkb .OR. jkb /= nkb) call errore ('dvpsi_e', 'unexpected error',1)
  IF (noncolin) THEN
     CALL zgemm( 'N', 'N', npw, nbnd_occ(ik)*npol, nkb, &
          (1.d0,0.d0), vkb(1,1), npwx, psc(1,1,1,1), nkb, (1.d0,0.d0), &
          dpsi, npwx )
     CALL zgemm( 'N', 'N', npw, nbnd_occ(ik)*npol, nkb, &
          (1.d0,0.d0),work(1,1), npwx, psc(1,1,1,2), nkb, (1.d0,0.d0), &
          dpsi, npwx )
  ELSE
     CALL zgemm( 'N', 'N', npw, nbnd_occ(ik), nkb, &
          (1.d0,0.d0), vkb(1,1), npwx, ps2(1,1,1), nkb, (1.d0,0.d0), &
          dpsi(1,1), npwx )
     CALL zgemm( 'N', 'N', npw, nbnd_occ(ik), nkb, &
          (1.d0,0.d0),work(1,1), npwx, ps2(1,1,2), nkb, (1.d0,0.d0), &
          dpsi(1,1), npwx )
  ENDIF

  IF (noncolin) THEN
     deallocate (psc)
     deallocate (deff_nc)
  ELSE
     deallocate (ps2)
     deallocate (deff)
  END IF
  deallocate (work)

  111 continue
  !
  !    orthogonalize dpsi to the valence subspace: ps = <evc|dpsi>
  !    Apply -P^+_c
  CALL orthogonalize(dpsi, evc, ik, ik, dvpsi)
  dpsi=-dpsi
  !
  !   dpsi contains P^+_c [H-eS,x] psi_v for the three crystal polarizations
  !   Now solve the linear systems (H-e_vS)*P_c(x*psi_v)=P_c^+ [H-e_vS,x]*psi_v
  !
  thresh = eth_rps
  h_diag=0.d0
  do ibnd = 1, nbnd_occ (ik)
     do ig = 1, npwq
        h_diag (ig, ibnd) = 1.d0 / max (1.0d0, g2kin (ig) / eprec (ibnd,ik) )
     enddo
     IF (noncolin) THEN
        do ig = 1, npwq
           h_diag (ig+npwx, ibnd) = 1.d0/max(1.0d0,g2kin(ig)/eprec(ibnd,ik))
        enddo
     END IF
  enddo
  !
  dvpsi(:,:) = (0.d0, 0.d0)
  !
  call cgsolve_all (ch_psi_all, cg_psi, et (1, ik), dpsi, dvpsi, &
       h_diag, npwx, npw, thresh, ik, lter, conv_root, anorm, &
       nbnd_occ (ik), npol)

  if (.not.conv_root) WRITE( stdout, '(5x,"ik",i4," ibnd",i4, &
       & " linter: root not converged ",e10.3)') &
       ik, ibnd, anorm
  !
  CALL flush_unit( stdout )
  !
  !
  ! we have now obtained P_c x |psi>.
  ! In the case of USPP this quantity is needed for the Born 
  ! effective charges, so we save it to disc
  !
  ! In the US case we obtain P_c x |psi>, but we need P_c^+ x | psi>,
  ! therefore we apply S again, and then subtract the additional term
  ! furthermore we add the term due to dipole of the augmentation charges.
  !
  if (okvan) then
     !
     ! for effective charges
     !
     nrec = (ipol - 1) * nksq + ik
     call davcio (dvpsi, lrcom, iucom, nrec, 1)
     !
     allocate (spsi ( npwx*npol, nbnd))    
     IF (noncolin) THEN
        CALL calbec (npw, vkb, dvpsi, becp_nc )
     ELSE
        CALL calbec (npw, vkb, dvpsi, becp )
     END IF
     CALL s_psi(npwx,npw,nbnd,dvpsi,spsi)
     call dcopy(2*npwx*npol*nbnd,spsi,1,dvpsi,1)
     deallocate (spsi)
     IF (noncolin) THEN
        call adddvepsi_us(becp2_nc,ipol,ik)
     ELSE
        call adddvepsi_us(becp2,ipol,ik)
     END IF
  endif

  IF (nkb > 0) THEN
     deallocate (dvkb1, dvkb)
     IF (noncolin) THEN
        deallocate(becp2_nc)
     ELSE
        deallocate(becp2)
     ENDIF
  END IF

  deallocate (h_diag)
  deallocate (aux)

  nrec = (ipol - 1)*nksq + ik
  call davcio(dvpsi, lrebar, iuebar, nrec, 1)
  this_pcxpsi_is_on_file(ik,ipol) = .true.
  call stop_clock ('dvpsi_e')
  return
end subroutine dvpsi_e

import Foundation

enum DemoRoutes {
    static let toWork = DemoRoute(polyline: #"itdmiAnlzxrCbDeDvHmF~As@|DiAzBe@zEq@`Gk@xC_@UsEe@yKu@sJg@qE_A}HaAmF{CsLsAcEk@{AaAiCcBsD}@oBkM_[mDaIaBsDfHsGfFgGjEcFxEyGfFyIdD}GtEiK~DeL`C}HpCiLvByK|AaKhAkK~AcO`BqK|BwL~BqJ`DcKfCgHxBcFdDeH|MuTbFaHkEeGmBmC_q@}~@_OoR}KeN}FyFwHeGeJaGgFyCqHaDcKqDmKcCwMoByMu@aMQ}tA`B{bBbDoLTgNl@k^rBio@hE_Jp@_DVuE\kF`@cYtBkb@pEaJxAmRlF{GxBqI|CwHtD}KnG{a@|VoK|GmDnBmFlCyBz@{BbAaDjAkIfB_BRyTlD_LdB_NrB_D^kzAlQmTjCoIfAaGp@kY~DgLbB{CVqALcCPqGDaEBsDIwTeA{M}@_I}@mHoA{FmBcO{GwFyC{XgPe@YsUePgPaL{OcL}OeLcGcEeIcEuIwCwF{AwJwAkG[mKFgKb@iJxA{InAmEf@wF^oIOeDYgBOyJuBqI{C{K_HaL_KwJoK{GeHk]__@yByBcGiHyBwB{UwT_TaQiL_JePyJkNoIsb@aSyLoEul@kTmLkEw`A_^mQuGeTiHuI_CyDcAwPgCem@uEw~@kHyk@uDyIa@}GDoJn@uIhAeFnAmAZ_GtAgGtBsH|C}LfHqMlIeUvL{IdDsGlB}FhAaI~@oEd@aGLqJNmNg@{TiCcTwC}gAgNmAKcFo@gJoAwFy@onAqPoC]pAmIbA{FnEgRpC_LhCkMpHuVzF_QnBeHzAyJTmIs@cGIyABwBv@}CnN}`@c\}Tka@{XmByAgU{PcH~PiB?}ALcAd@gAz@e@r@sBlFOz@OvAA~ARzBv@~B`K}V"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 91.1, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 299.7, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .stopSign),
        DemoSegment(at: 734.9, road: DemoRoad(name: "Ashburn Road", highway: "secondary", mph: 40), control: .light),
        DemoSegment(at: 5232.0, road: DemoRoad(name: "", highway: "service", mph: 15), control: .none),
    ])

    static let toHome = DemoRoute(polyline: #"cdloiAvlywrC`AcCbH_QfUzPlBxAja@zXb\|ToN|`@w@|CCvBHxAr@bGUlI{AxJoBdH{F~PqHtViCjMqC~KoEfRcAzFqAlInC\nnApPvFx@fJnAbFn@lAJ|gAfNbTvCzThClNf@pJO`GMnEe@`I_A|FiArGmBzIeDdUwLpMmI|LgHrH}CfGuB~FuAlA[dFoAtIiAnJo@|GExI`@xk@tDv~@jHdm@tEvPfCxDbAtI~BdThHlQtGv`A~]lLjEtl@jTxLnErb@`SjNnIdPxJhL~I~S`QzUvTxBvBbGhHxBxBj]~^zGdHvJnK`L~JzK~GpIzCxJtBfBNdDXnINvF_@lEg@zIoAhJyAfKc@lKGjGZvJvAvFzAtIvCdIbEbGbE|OdLzObLfP`LrUdPd@XzXfPvFxCbOzGzFlBlHnA~H|@zM|@vTdArDH`ECpGEbCQpAMzCWfLcBjY_E`Gq@nIgAlTkCjzAmQ~C_@~MsB~KeBxTmD~ASjIgB`DkAzBcAxB{@lFmClDoBnK}Gza@}V|KoGvHuDpI}CzGyBlRmF`JyAjb@qEbYuBjFa@tE]~CW~Iq@ho@iEj^sBfNm@nLUzbBcD|tAaB`MPxMt@vMnBlKbCbKpDpH`DfFxCdJ`GvHdG|FxF|KdN~NnR~p@|~@lBlCaF`HqLxR_GhLuCpGkE`MeBfH{CdO_D|R}D~\uCfQaCpLyC~KuCzIkClHwChGsD`HkElG}ErGeFhGaLfKxCzG`BrDlD`IjM~Z|@nBbBrD`AhCj@zArAbEzCrL`AlF~@|Hf@pEt@rJd@xKTrEyC^aGj@{Ep@{Bd@}DhA_Br@wHlFcDdD"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "", highway: "service", mph: 15), control: .none),
        DemoSegment(at: 512.0, road: DemoRoad(name: "Ashburn Road", highway: "secondary", mph: 40), control: .stopSign),
        DemoSegment(at: 4993.1, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .light),
        DemoSegment(at: 5426.5, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 5650.1, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
    ])

    static let toSchool = DemoRoute(polyline: #"itdmiAnlzxrCbDeDvHmF~As@|DiAzBe@zEq@`Gk@xC_@UsEe@yKu@sJg@qE_A}HaAmF{CsLsAcEk@{AaAiCcBsD}@oBkM_[mDaIaBsDyC{Gy@t@yP|KqG~CgLlEsKbDaHfA{Gl@gLv@mPnAgJjAeGlAsI`CeJ|CsHdDgIxEkGzDuG|EsG`GmHhI}GtIkGjJiGtKcElJyDpJmDnKgCjJeC`L_CzMaBbMiAnN_@dF[xGQrGIfFC|e@`@``C@rE[xXUbMe@nJg@`HaA~K{AjLaB|JuBdK}AvGkChJsCnJSh@uB~F{EjLsD~H}CbFyH~Kid@xo@gExGmDjGyDpIsEtKwBlGoTbu@sArEyDyBqx@ae@aGmD}M{GuI{DwHgCiJgCmI}A_HiAyEu@yHJ{RWgJLwL|@sANgI~@wI`BaLhCeLdDoJbEiM~HkHxE}HzFeHtGkGjGeGlHqKlOqj@`aAqr@dmAsGbKuIlKcG~Fk@j@_HnFmEpCgJnEcHpCcHpC{I~BeI~A{Gz@gHZuKCsK[cKy@gSoCsEy@aGoAy@|Jk@vGcLdmAiE`c@e@pJQvFSjGC~CoGS{`@s@g[cJmF_DyIeIeMqLaE{AoCReCpA{FbM_E|H"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 91.1, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 299.7, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .stopSign),
        DemoSegment(at: 1782.3, road: DemoRoad(name: "Claiborne Parkway", highway: "primary", mph: 45), control: .light),
        DemoSegment(at: 3053.2, road: DemoRoad(name: "Hay Road", highway: "tertiary", mph: 35), control: .light),
        DemoSegment(at: 3290.0, road: DemoRoad(name: "", highway: "service", mph: 15), control: .none),
    ])

    static let fromSchool = DemoRoute(polyline: #"auiniA~qyyrCs@vEpAvGtc@~b@~CtB|DC|BsBjO{\p@eBtIhC~Fv@nCFlP^vJJtG@DkGB_DRkGPwFd@qJhEac@bLemAj@wGvGxAvJfBpLdBzIv@xFTxPFvFOvD[~@IbGy@jF_ArJ{BvKmDnRyJrIcGnH{FtFeFzFuGdG{HjFqIlp@gjA~f@a|@dMeS~GyIfHeHtRaOzD_CnDsBhOgHfLcE`G_BdQmDjD_@zAOrLqA~QWzGNpHb@|BXtEf@jEf@nHpAtNpD|OzFvDdBfPlJfy@df@pC|A`GrDpCaJbBgFbQ}k@|CsJ~C_J|BsFjEqIpG_LhWq^zGyJlFuHnIqMpJ_SnEeLfDoJ|ByHpB{HfCaMrB}KxAsKpAwKr@aKf@uIZaLTsL@iR@eFYqyCFkNRyIXuH`@wFf@iGx@_Iz@wGxAmI|AqHpA}F~BkIpBiGpBwFvCaHnCaGlEiI|DiGrDgFtEeGnFoFrHgH~JsHpEqCdEsBvDiBvFcCvIkCzL{C`KkAdHs@bLm@rG_@jGkAtHuA|F_B~GsBtH_D|K}FjE{C`IcG`BrDlD`IjM~Z|@nBbBrD`AhCj@zArAbEzCrL`AlF~@|Hf@pEt@rJd@xKTrEyC^aGj@{Ep@{Bd@}DhA_Br@wHlFcDdD"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "", highway: "service", mph: 15), control: .none),
        DemoSegment(at: 299.6, road: DemoRoad(name: "Hay Road", highway: "tertiary", mph: 35), control: .stopSign),
        DemoSegment(at: 531.1, road: DemoRoad(name: "Claiborne Parkway", highway: "primary", mph: 45), control: .light),
        DemoSegment(at: 1796.5, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .light),
        DemoSegment(at: 3289.9, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 3498.5, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
    ])

    static let toStore = DemoRoute(polyline: #"itdmiAnlzxrCbDeDvHmF~As@|DiAzBe@zEq@`Gk@xC_@UsEe@yKu@sJg@qE_A}HaAmF{CsLsAcEk@{AaAiCcBsD}@oBkM_[mDaIaBsDfHsGfFgGjEcFxEyGfFyIdD}GtEiK~DeL`C}HpCiLvByK|AaKhAkK~AcO`BqK|BwL~BqJ`DcKfCgHxBcFdDeH|MuTbFaHbC|CvKfMvFtH~TlZxgCdkDxC`EnUf[hN~PxHxIvQfPnUlQdMxGxJhF|O|Gp@ZdQfGfCp@nJrCpx@hVj|Bvp@fBh@bCt@zEpA|Ct@bBd@d{@tVtHbBbNxA~JfAhMr@v[p@bJRhEDpCD`UhBlOnAvPrAfFJdAiQHaBd@sVVkc@?wQYcPWue@Fo[f@qZnF?bA?lB@tGYzHq@bHcBtGyB~EwBnD{BdIuGd@WvCwAhEkDfEyEhEwE`IwHvIyFtF{CtBy@tBy@dGaBpFy@vEo@|IYbKStE@MpH[pUIlSDjMd@pVt@dPnAtQfBlSfC~R|CxRlGf\hWrtA`Njs@pMxp@rEhUnMfm@tFpW~GhXzAhGnBdIbAhEhEpNzFjO~E`LvEtJzF~JjFfIpF~Hd]da@pI~JzWrZzEtFzEtFkCrEoEpH_GfJuE`JBbEjBdBx@fBHlCD`L@zC"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 91.1, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 299.7, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .stopSign),
        DemoSegment(at: 734.9, road: DemoRoad(name: "Ashburn Road", highway: "secondary", mph: 40), control: .light),
        DemoSegment(at: 2345.1, road: DemoRoad(name: "Waxpool Road", highway: "primary", mph: 45), control: .light),
        DemoSegment(at: 2639.4, road: DemoRoad(name: "Shellhorn Road", highway: "secondary", mph: 45), control: .light),
        DemoSegment(at: 2996.9, road: DemoRoad(name: "Ashburn Village Boulevard", highway: "secondary", mph: 40), control: .light),
        DemoSegment(at: 3769.6, road: DemoRoad(name: "Mooreview Parkway", highway: "tertiary", mph: 35), control: .none),
        DemoSegment(at: 4135.4, road: DemoRoad(name: "Southern Walk Plaza", highway: "service", mph: 15), control: .none),
    ])

    static let fromStore = DemoRoute(polyline: #"ozzkiAxqlyrCA{CEaLImCy@gBkBeB{FJgCBs@@mC?wGHq@@_CEwCc@wAeA{@wBYuAeGyYcBeIaFvByHlBwKrA_Mp@aJfBiF`B{EpB_FtCcCjB{AhAaBtAsBpBaFtFkGlJq}Ar{CaE`I_IrOoFnKcCxE{E|GgFtFyFzEkG|DyHhDyPbFyB~@{CxA}CdBsDfCs@l@}CrCqArA_EpEyEhH}D~HkFnN_ExI{EzHiEpFaF~EmGzEgH|DmEdB{HxBmG`AiIh@iICqGe@cSeDsEm@t@sJ|Gi|@fEiz@jB}V~Ecq@nCw\dBqUv@}]Hqc@b@axAWe{@n@u^LkFFmD`@sXd@cSl@{Q`AmQjAcMHk@hGg`@dBmKbZmjBdAqHdAoJ`@{DrAwLlAsQ~@iLgFKwPsAmOoAaUiBqCEiEEcJSw[q@iMs@_KgAcNyAuHcBe{@uVcBe@}Cu@{EqAcCu@gBi@k|Bwp@qx@iVoJsCgCq@eQgGq@[}O}GyJiFeMyGoUmQwQgPyHyIiN_QoUg[yCaEygCekD_UmZwFuHwKgMcC}CkEeGaF`HqLxR_GhLuCpGkE`MeBfH{CdO_D|R}D~\uCfQaCpLyC~KuCzIkClHwChGsD`HkElG}ErGeFhGaLfKxCzG`BrDlD`IjM~Z|@nBbBrD`AhCj@zArAbEzCrL`AlF~@|Hf@pEt@rJd@xKTrEyC^aGj@{Ep@{Bd@}DhA_Br@wHlFcDdD"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "Southern Walk Plaza", highway: "service", mph: 15), control: .none),
        DemoSegment(at: 181.3, road: DemoRoad(name: "Demott Drive", highway: "tertiary", mph: 30), control: .stopSign),
        DemoSegment(at: 1247.4, road: DemoRoad(name: "Waxpool Road", highway: "primary", mph: 45), control: .light),
        DemoSegment(at: 2437.1, road: DemoRoad(name: "Ashburn Road", highway: "secondary", mph: 40), control: .light),
        DemoSegment(at: 4047.3, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .light),
        DemoSegment(at: 4496.7, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 4720.3, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
    ])

    static let lap = DemoRoute(polyline: #"itdmiAnlzxrCbDeDvHmF~As@|DiAzBe@zEq@`Gk@xC_@UsEe@yKu@sJg@qE_A}HaAmF{CsLsAcEk@{AaAiCcBsD}@oBkM_[mDaIaBsDfHsGfFgGjEcFxEyGfFyIdD}GtEiK~DeL`C}HpCiLvByK|AaKkGyAaEeA}Cy@eDoAmIcFaFkEuDqEyCiEyCmE}N{TuOwVeGqHmJ}GkJcEwFwAuH}@mGQLiG@_L}Dof@g@cGgIecAsj@x@{A~@QbAO|AX~[VzB`L~f@h@|AbBt@nAInd@wH|Dnf@A~KMhGlGPtH|@vFvAjJbElJ|GdGpHtOvV|NzTxClExChEtDpE`FjElIbFdDnA|Cx@`EdAuCfQaCpLyC~KuCzIkClHwChGsD`HkElG}ErGeFhGaLfKxCzG`BrDlD`IjM~Z|@nBbBrD`AhCj@zArAbEzCrL`AlF~@|Hf@pEt@rJd@xKTrEyC^aGj@{Ep@{Bd@}DhA_Br@wHlFcDdD"#, segments: [
        DemoSegment(at: 0.0, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 91.1, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 299.7, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .stopSign),
        DemoSegment(at: 518.7, road: DemoRoad(name: "Summerwood Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 836.6, road: DemoRoad(name: "Stonebridge Drive", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 1029.6, road: DemoRoad(name: "Crocus Terrace", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 1309.2, road: DemoRoad(name: "Stonebridge Drive", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 1394.5, road: DemoRoad(name: "Summerwood Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 1697.0, road: DemoRoad(name: "Ashburn Farm Parkway", highway: "secondary", mph: 35), control: .stopSign),
        DemoSegment(at: 1905.8, road: DemoRoad(name: "Golden Meadow Circle", highway: "residential", mph: 25), control: .none),
        DemoSegment(at: 2129.4, road: DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25), control: .none),
    ])
}

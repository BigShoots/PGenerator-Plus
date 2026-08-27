/* Batched 3D LUT node solve for usr/bin/meter_lg_3d_autocal.pl.
   One invocation per cube: the model arrives on stdin as text, the complete
   u16 code vector leaves on stdout as text. Every routine here mirrors the
   Perl sub it is named after so the two can be diffed line for line.

   Parity is the contract, not speed. fm_invert is a discrete-branch search:
   a last-ulp difference does not shift the answer by 1e-13, it flips an
   accept test and the two implementations then walk different trials. So the
   IDW accumulation order, the Jacobian dot-product order and every clamp are
   reproduced exactly, and the build pins -ffp-contract=off. The branch-cliff
   margins are measured on every run and reported on stderr; three of them
   also refuse the cube, at which point the caller falls back to Perl. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "../common/pgen_colour_math.h"

#define PROTO_VERSION 1
#define MAXRAMP 256
#define MAXLVL  64
#define MAXNODE 65

/* Gate thresholds. Every margin below is measured and reported on every run;
   only three of the five are allowed to refuse a cube, and the split is set
   by measurement rather than by symmetry.
   Across six models x sizes 9/17/33 x both node orders (507,696 codes, zero
   mismatches against the Perl path) the convergence, IDW and determinant
   margins never came within six orders of magnitude of these thresholds, so
   gating on them is free insurance.
   The accept-test margin and the quantise margin are reported only. Both
   reach exactly 0.000e+00 on ordinary models while the emitted codes stay
   byte-identical: a near-tie in `tn < best_e` means the two trials are
   equally good and the answer does not move, and the exact mid-grey node
   lands on literally 50.0 percent -- 2048.0 code units -- whenever greys are
   solved instead of held at identity. Refusing on either would turn the
   helper permanently off on the models where it is worth the most. Parity at
   those nodes is guaranteed instead by the caller's 64-node runtime
   self-check, which covers the neutral diagonal, and by the byte-identical
   sweep in t/lg_3d_lut_native_parity.t. */
#define GATE_CONV   1e-15       /* absolute, |best_e-2e-4|; min measured 6.2e-10 */
#define GATE_IDW    1e-18       /* absolute, |d2-1e-12|;   min measured 8.6e-11 */
#define GATE_DET    1e-9        /* relative, ||det|-1e-12|/|det|; min measured 1.0 */

typedef struct { double lv; double xyz[3]; } samp;

static int    g_size=17;
static int    g_order=0;                  /* 1 = r slowest (.cube), 0 = r fastest (LG payload) */
static int    g_neutral_identity=1;
static int    g_neutral_nbhd=0;
static char   g_gamma_raw[32]="bt1886";   /* gamut_matrix_output's gexp test is case sensitive */
static char   g_gamma[32]="bt1886";       /* lc(), what target_gamma_linear sees */
static double g_white_y=0, g_chroma_white_y=0, g_node_white_y=0;
static double g_black[3]={0,0,0};
static double g_gm[3][3];                 /* rgb_to_xyz_matrix_for_gamut(target_gamut) */
static double g_drive[3][3];              /* gamut_drive_matrix */
static int    g_seed_matrix=-1;
static int    g_clc=0; static double g_clc_s=0;
static int    g_msb=0; static double g_msb_s=0;
static samp   g_ramp[3][MAXRAMP]; static int g_nramp[3]={-1,-1,-1};
static samp   g_wax[MAXLVL]; static int g_nwax=0, g_have_wax=0;
static samp   g_contrib[3][MAXLVL]; static int g_ncontrib[3]={-1,-1,-1};
static double g_peak_y[3]={1,1,1};
static double g_peak_inverse[3][3];
static double (*g_naf)[3]=NULL, (*g_nad)[3]=NULL; static int g_nna=-1;

static const int RAMP_LEVELS[17]={0,2,5,8,12,16,20,30,40,50,60,70,80,88,94,98,100};

static double g_min_accept=1e300, g_min_conv=1e300, g_min_idw=1e300, g_min_det=1e300;
static double g_min_quant=1e300; static int g_quant_node[3]={-1,-1,-1};
static long g_iters=0, g_trials=0, g_quant_n=0, g_quant_hist[8];

static void fail(const char *why){
 printf("PGLUT3D %d error %s\n",PROTO_VERSION,why);
 exit(1);
}

static double clampd(double v,double lo,double hi){
 if(v < lo) return lo;
 if(v > hi) return hi;
 return v;
}

/* _fm_ramp_interp (meter_lg_3d_autocal.pl) */
static void ramp_interp(const samp *a,int n,double f,double *o){
 int i,k;
 if(!n){ o[0]=o[1]=o[2]=0; return; }
 if(f < 0) f=0;
 if(f > 1) f=1;
 if(f <= a[0].lv){ for(k=0;k<3;k++) o[k]=a[0].xyz[k]; return; }
 for(i=0;i<n-1;i++){
  if(f <= a[i+1].lv){
   double l0=a[i].lv,l1=a[i+1].lv;
   double t=(l1 > l0) ? (f-l0)/(l1-l0) : 0.0;
   for(k=0;k<3;k++) o[k]=a[i].xyz[k]*(1-t)+a[i+1].xyz[k]*t;
   return;
  }
 }
 for(k=0;k<3;k++) o[k]=a[n-1].xyz[k];
}

/* interpolate_vec_by_level. Samples arrive pre-sorted ascending; the helper
   must never re-sort, Perl's numeric key sort is the total order of record. */
static void interp_samples(const samp *a,int n,double level,double *o){
 int i,k;
 if(n < 1){ o[0]=o[1]=o[2]=0; return; }
 if(level <= a[0].lv){ for(k=0;k<3;k++) o[k]=a[0].xyz[k]; return; }
 if(level >= a[n-1].lv){ for(k=0;k<3;k++) o[k]=a[n-1].xyz[k]; return; }
 for(i=1;i<n;i++){
  double l0,l1,t;
  if(level > a[i].lv) continue;
  l0=a[i-1].lv; l1=a[i].lv; t=(level-l0)/(l1-l0);
  for(k=0;k<3;k++) o[k]=a[i-1].xyz[k]*(1-t)+a[i].xyz[k]*t;
  return;
 }
 for(k=0;k<3;k++) o[k]=a[n-1].xyz[k];
}

/* fm_additive + fm_nonadd_corr, fused. The additive term is finished before
   any correction is added, in the same order, so this is arithmetically the
   same expression as fm_forward's componentwise sum of the two. */
static void fm_forward(double dr,double dg,double db,double *o){
 double R[3],G[3],B[3],acc[3];
 double sw=0;
 int k,i;
 ramp_interp(g_ramp[0],g_nramp[0],dr,R);
 ramp_interp(g_ramp[1],g_nramp[1],dg,G);
 ramp_interp(g_ramp[2],g_nramp[2],db,B);
 for(k=0;k<3;k++) o[k]=R[k]+G[k]+B[k]-2*g_black[k];
 if(g_nna <= 0) return;
 acc[0]=acc[1]=acc[2]=0;
 for(i=0;i<g_nna;i++){
  double d2=0,df,w,m;
  df=g_naf[i][0]-dr; d2+=df*df;
  df=g_naf[i][1]-dg; d2+=df*df;
  df=g_naf[i][2]-db; d2+=df*df;
  /* Distance from the early-exit cliff, tracked unconditionally. This is the
     innermost loop in the program (2.4e9 iterations for a 65^3 dense cube) and
     the subtract and fabs cost 20% of total runtime -- 0.7 s of 3.8 s, against
     a Perl baseline in the tens of minutes, so the visibility is worth it.
     Guarding it behind `if(d2 < 1e-9)` was measured SLOWER (3.98 s) than doing
     it unconditionally (3.80 s): the extra branch costs more than the fabs. */
  m=fabs(d2-1e-12);
  if(m < g_min_idw) g_min_idw=m;
  if(d2 < 1e-12){ for(k=0;k<3;k++) o[k]+=g_nad[i][k]; return; }
  w=1.0/(d2*d2 + 1e-8);
  sw+=w;
  for(k=0;k<3;k++) acc[k]+=w*g_nad[i][k];
 }
 if(sw <= 0) return;
 for(k=0;k<3;k++) o[k]+=acc[k]/sw;
}

/* matrix_inverse */
static int mat_inv(const double m[3][3],double out[3][3]){
 double det,ad,rel;
 int valid=pgen_matrix3_inverse(m,out,1e-12,&det);
 ad=fabs(det);
 rel=fabs(ad-1e-12)/(ad > 1e-12 ? ad : 1e-12);
 if(rel < g_min_det) g_min_det=rel;
 return valid;
}

/* matrix_mul_vec */
static void mat_vec(const double m[3][3],const double *v,double *o){
 o[0]=m[0][0]*v[0]+m[0][1]*v[1]+m[0][2]*v[2];
 o[1]=m[1][0]*v[0]+m[1][1]*v[1]+m[1][2]*v[2];
 o[2]=m[2][0]*v[0]+m[2][1]*v[1]+m[2][2]*v[2];
}

/* st2084_pq_to_linear */
static double st2084_to_linear(double s){
 return pgen_pq_decode_normalized(s);
}

/* target_gamma_linear */
static double gamma_linear(double s,const char *gm){
 s=clampd(s,0,1);
 if(!strcmp(gm,"srgb")) return (s <= 0.04045) ? (s/12.92) : pow((s+0.055)/1.055,2.4);
 if(!strcmp(gm,"st2084")) return st2084_to_linear(s);
 return pow(s,(!strcmp(gm,"2.2")) ? 2.2 : 2.4);
}

/* bt1886_luminance_y */
static double bt1886_luminance_y(double s,double wy,double by){
 double g=2.4;
 s=clampd(s,0,1);
 if(!(wy > 0)) wy=100;
 if(!(by >= 0)) by=0;
 if(by >= wy) by=0;
 return pow((pow(wy,1/g) - pow(by,1/g))*s + pow(by,1/g),g);
}

/* bt1886_relative_luminance */
static double bt1886_rel(double s,double wy,double by){
 double range;
 if(!(wy > 0)) wy=100;
 if(!(by >= 0)) by=0;
 range=wy-by;
 if(range <= 1e-9) return gamma_linear(s,"2.4");
 return clampd((bt1886_luminance_y(s,wy,by)-by)/range,0,1);
}

/* target_relative_luminance */
static double target_rel(double s,double wy,double by){
 if(!strcmp(g_gamma,"bt1886")) return bt1886_rel(s,wy,by);
 return gamma_linear(s,g_gamma);
}

/* rgb_to_xyz_for_gamut, with the gamut matrix precomputed by Perl */
static void gamut_xyz(double r,double g,double b,double wy,double *o){
 if(!(wy > 0)) wy=100;
 o[0]=(g_gm[0][0]*r + g_gm[0][1]*g + g_gm[0][2]*b) * wy;
 o[1]=(g_gm[1][0]*r + g_gm[1][1]*g + g_gm[1][2]*b) * wy;
 o[2]=(g_gm[2][0]*r + g_gm[2][1]*g + g_gm[2][2]*b) * wy;
}

/* target_rgb_to_xyz */
static void target_rgb_to_xyz(double r,double g,double b,double wy,double *o){
 int k;
 if(!(wy > 0)) wy=100;
 if(!strcmp(g_gamma,"bt1886")){
  double by=g_black[1],range=wy-by,lr,lg,lb;
  if(range <= 1e-9) range=wy;
  lr=target_rel(r,wy,by); lg=target_rel(g,wy,by); lb=target_rel(b,wy,by);
  gamut_xyz(lr,lg,lb,range,o);
  for(k=0;k<3;k++) o[k]=g_black[k]+o[k];
  return;
 }
 gamut_xyz(gamma_linear(r,g_gamma),gamma_linear(g,g_gamma),gamma_linear(b,g_gamma),wy,o);
}

/* target_xyz_for_node / fm_target_for_node */
static void target_for_node(int ri,int gi,int bi,int size,double *o){
 double r=(double)ri/(size-1),g=(double)gi/(size-1),b=(double)bi/(size-1);
 if(ri==gi && gi==bi && g_have_wax){ interp_samples(g_wax,g_nwax,r*100,o); return; }
 target_rgb_to_xyz(r,g,b,g_node_white_y,o);
}

/* channel_inverse_level */
static double channel_inverse_level(int ch,double linear){
 double peak=g_peak_y[ch] ? g_peak_y[ch] : 1;
 double y[17];
 int i,j;
 linear=clampd(linear,0,1);
 for(i=0;i<17;i++){
  double v=0;
  if(RAMP_LEVELS[i] != 0){
   const samp *s=NULL;
   for(j=0;j<g_ncontrib[ch];j++) if(g_contrib[ch][j].lv == (double)RAMP_LEVELS[i]){ s=&g_contrib[ch][j]; break; }
   v=(s && s->xyz[1]) ? s->xyz[1] : 0;
   v=v/peak;
  }
  if(v < 0) v=0;
  y[i]=v;
 }
 for(i=1;i<17;i++){
  double y0,y1;
  int l0,l1;
  if(linear > y[i]) continue;
  y0=y[i-1]; y1=y[i]; l0=RAMP_LEVELS[i-1]; l1=RAMP_LEVELS[i];
  if(fabs(y1-y0) < 1e-9) return l1;
  return l0 + ((linear-y0)/(y1-y0))*(l1-l0);
 }
 return 100;
}

/* matrix_for_level */
static void matrix_for_level(double level,double m[3][3]){
 double lin=target_rel(level/100,g_white_y,g_black[1] ? g_black[1] : 0),s;
 int kind,k;
 if(lin <= 1e-9) lin=1;
 s=1/lin;
 for(kind=0;kind<3;kind++){
  double v[3];
  interp_samples(g_contrib[kind],g_ncontrib[kind],level,v);
  for(k=0;k<3;k++) m[k][kind]=v[k]*s;
 }
}

/* solve_output_rgb */
static void solve_output_rgb(const double *target,int ri,int gi,int bi,int size,double *o){
 double delta[3],m[3][3],inv[3][3],lin[3],pct[3],node_peak,mx;
 int mxi=ri,k;
 for(k=0;k<3;k++) delta[k]=target[k]-g_black[k];
 if(gi > mxi) mxi=gi;
 if(bi > mxi) mxi=bi;
 node_peak=100.0*mxi/(size-1);
 matrix_for_level(node_peak,m);
 if(!mat_inv(m,inv)) memcpy(inv,g_peak_inverse,sizeof inv);
 mat_vec(inv,delta,lin);
 for(k=0;k<3;k++) pct[k]=channel_inverse_level(k,clampd(lin[k],0,1));
 mx=pct[0];
 if(pct[1] > mx) mx=pct[1];
 if(pct[2] > mx) mx=pct[2];
 if(mx > 100) for(k=0;k<3;k++) pct[k]=pct[k]*(100/mx);
 for(k=0;k<3;k++) o[k]=clampd(pct[k],0,100);
}

/* gamut_matrix_output */
static void gamut_matrix_output(int ri,int gi,int bi,int size,double *o){
 double gexp=(!strcmp(g_gamma_raw,"2.4") || !strcmp(g_gamma,"bt1886")) ? 2.4 : 2.2;
 double lin[3];
 int k;
 lin[0]=gamma_linear((double)ri/(size-1),g_gamma);
 lin[1]=gamma_linear((double)gi/(size-1),g_gamma);
 lin[2]=gamma_linear((double)bi/(size-1),g_gamma);
 mat_vec(g_drive,lin,o);
 if(g_clc){
  double wy=g_white_y,cw=g_chroma_white_y;
  if(wy > 0 && cw > 0 && cw < wy*0.98){
   int mx=ri,mn=ri;
   if(gi > mx) mx=gi;
   if(bi > mx) mx=bi;
   if(gi < mn) mn=gi;
   if(bi < mn) mn=bi;
   if(mx > 0 && mx > mn){
    double sat=(double)(mx-mn)/mx;
    double w=sat*sat*(1-sat)*6.75,st=g_clc_s,sc;
    if(w > 1) w=1;
    if(w < 0) w=0;
    if(!(st > 0)) st=0.8;
    if(st > 1.5) st=1.5;
    sc=pow(cw/wy,w*st);
    for(k=0;k<3;k++) o[k]=o[k]*sc;
   }
  }
 }
 for(k=0;k<3;k++) o[k]=pow(clampd(o[k],0,1),1.0/gexp)*100;
}

/* _fm_err */
static double fm_err(const double *target,const double *d,double *e){
 double f[3];
 fm_forward(d[0],d[1],d[2],f);
 e[0]=target[0]-f[0]; e[1]=target[1]-f[1]; e[2]=target[2]-f[2];
 return sqrt(e[0]*e[0]+e[1]*e[1]+e[2]*e[2]);
}

/* fm_invert */
static void fm_invert(const double *target,const double *seed_pct,double *out){
 double best[3],best_err[3],best_e,h=0.015,lambda=1e-2;
 int ch,iter,tryi,a,bc,row;
 for(ch=0;ch<3;ch++){ double v=seed_pct[ch]/100; best[ch]=v<0?0:(v>1?1:v); }
 best_e=fm_err(target,best,best_err);
 for(iter=0;iter<18;iter++){
  double cols[3][3],JtJ[3][3],Jte[3],m;
  int improved=0;
  g_iters++;
  m=fabs(best_e-2e-4);
  if(m < g_min_conv) g_min_conv=m;
  if(best_e < 2e-4) break;
  for(ch=0;ch<3;ch++){
   double dp[3],dm[3],span,fp[3],fn[3];
   memcpy(dp,best,sizeof dp);
   memcpy(dm,best,sizeof dm);
   dp[ch]=best[ch]+h; if(dp[ch] > 1) dp[ch]=1;
   dm[ch]=best[ch]-h; if(dm[ch] < 0) dm[ch]=0;
   span=dp[ch]-dm[ch]; if(span <= 0) span=h;
   fm_forward(dp[0],dp[1],dp[2],fp);
   fm_forward(dm[0],dm[1],dm[2],fn);
   cols[ch][0]=(fp[0]-fn[0])/span;
   cols[ch][1]=(fp[1]-fn[1])/span;
   cols[ch][2]=(fp[2]-fn[2])/span;
  }
  for(a=0;a<3;a++){
   double s;
   for(bc=0;bc<3;bc++){ s=0; for(row=0;row<3;row++) s+=cols[a][row]*cols[bc][row]; JtJ[a][bc]=s; }
   s=0; for(row=0;row<3;row++) s+=cols[a][row]*best_err[row];
   Jte[a]=s;
  }
  for(tryi=0;tryi<6;tryi++){
   double M[3][3],inv[3][3];
   /* Perl truthiness, not a magnitude test: 0 and -0.0 both substitute 1e-9. */
   for(a=0;a<3;a++) for(bc=0;bc<3;bc++)
    M[a][bc]=JtJ[a][bc] + ((a==bc) ? lambda*(JtJ[a][a] ? JtJ[a][a] : 1e-9) : 0);
   if(mat_inv(M,inv)){
    double step[3],sn,trial[3],te[3],tn,gap;
    mat_vec(inv,Jte,step);
    sn=sqrt(step[0]*step[0]+step[1]*step[1]+step[2]*step[2]);
    if(sn > 0.25){ double s=0.25/sn; step[0]*=s; step[1]*=s; step[2]*=s; }
    for(ch=0;ch<3;ch++){ double v=best[ch]+step[ch]; trial[ch]=v<0?0:(v>1?1:v); }
    tn=fm_err(target,trial,te);
    g_trials++;
    /* Only a trial that actually moved the forward model can put the accept
       test on a cliff. The LM routinely proposes a step so small that the
       piecewise-linear ramp returns the same XYZ bits, giving tn == best_e
       exactly; that is a structural tie, not a near-miss, and counting it
       would peg the margin at zero on most models. */
    if(memcmp(trial,best,sizeof trial) != 0 && memcmp(te,best_err,sizeof te) != 0){
     gap=fabs(tn-best_e)/(best_e > 0 ? best_e : 1);
     if(gap < g_min_accept) g_min_accept=gap;
    }
    if(tn < best_e){
     memcpy(best,trial,sizeof best);
     memcpy(best_err,te,sizeof best_err);
     best_e=tn;
     lambda*=0.5;
     if(lambda < 1e-6) lambda=1e-6;
     improved=1;
     break;
    }
   }
   lambda*=4;
  }
  if(!improved) break;
 }
 out[0]=best[0]*100; out[1]=best[1]*100; out[2]=best[2]*100;
}

/* neutral_identity_output */
static int neutral_identity(int r,int g,int b,int size,double *o){
 int den,mn,mx;
 if(!g_neutral_identity) return 0;
 if(size < 2) size=2;
 den=size-1;
 mn=r; if(g < mn) mn=g; if(b < mn) mn=b;
 mx=r; if(g > mx) mx=g; if(b > mx) mx=b;
 if(!g_neutral_nbhd){ if(!(r==g && g==b)) return 0; }
 else { if(mx-mn > 1) return 0; }
 o[0]=100.0*r/den; o[1]=100.0*g/den; o[2]=100.0*b/den;
 return 1;
}

/* node_output_pct, forward_model branch only. The matrix / residual_grid
   branch stays in Perl; Perl must never call this helper for such a model. */
static int node_output_pct(int r,int g,int b,int size,double *o){
 double target[3],seed[3],inv[3],f[3],mx,mn,sat;
 int den,k;
 if(neutral_identity(r,g,b,size,o)) return 1;
 target_for_node(r,g,b,size,target);
 if(g_seed_matrix) gamut_matrix_output(r,g,b,size,seed);
 else solve_output_rgb(target,r,g,b,size,seed);
 fm_invert(target,seed,inv);
 den=size-1; if(den < 1) den=1;
 f[0]=(double)r/den; f[1]=(double)g/den; f[2]=(double)b/den;
 mx=f[0]; if(f[1] > mx) mx=f[1]; if(f[2] > mx) mx=f[2];
 mn=f[0]; if(f[1] < mn) mn=f[1]; if(f[2] < mn) mn=f[2];
 sat=(mx > 1e-9) ? ((mx-mn)/mx) : 0;
 if(sat < 0.12){
  double w=(sat <= 0.03) ? 0 : ((sat-0.03)/(0.12-0.03));
  for(k=0;k<3;k++) o[k]=seed[k]*(1-w)+inv[k]*w;
  return 0;
 }
 if(g_msb){
  double env=sat*sat*(1-sat)*6.75,st=g_msb_s,w;
  if(env > 1) env=1;
  if(env < 0) env=0;
  if(!(st > 0)) st=0.55;
  if(st > 1.0) st=1.0;
  w=env*st;
  if(w > 0){ for(k=0;k<3;k++) o[k]=inv[k]*(1-w)+seed[k]*w; return 0; }
 }
 for(k=0;k<3;k++) o[k]=inv[k];
 return 0;
}

/* ---- quantise margin ---------------------------------------------------
   Distance of the pre-quantisation value from the point where int() changes
   answer, in code units. Only tracked for solved nodes whose output is
   strictly inside (0,100): a neutral-identity node and a clamped 0/100 are
   integer-derived and bit-identical in both languages by construction. */
static const double MARGIN_BUCKET[8]={1,1e-1,1e-2,1e-3,1e-4,1e-5,1e-6,1e-7};

static void margin_note(double v,int r,int g,int b){
 double q,fr,m;
 int k;
 if(!(v > 0) || !(v < 100)) return;
 q=clampd(v,0,100)*4095/100+0.5;
 fr=q-floor(q);
 m=(fr < 0.5) ? fr : (1.0-fr);
 g_quant_n++;
 for(k=0;k<8;k++){ if(m >= MARGIN_BUCKET[k]) break; g_quant_hist[k]++; }
 if(m < g_min_quant){ g_min_quant=m; g_quant_node[0]=r; g_quant_node[1]=g; g_quant_node[2]=b; }
}

/* ---- protocol -----------------------------------------------------------
   ASCII, LF line endings, one directive per line, first token is the key.
   Every double is written by Perl with %.17g and read here with strtod;
   Perl's default stringification is %.15g and is NOT round-trip exact for
   binary64, so a single interpolated model value would perturb the cube.

   REQUEST (stdin)                     bumped version => Perl refuses and falls back
     PGLUT3D 1                         magic + version, must be line 1
     size <int>                        9 | 17 | 33 | 65
     order r_slowest | r_fastest       .cube fill order | LG payload fill order
     neutral_axis_identity <0|1>
     neutral_neighborhood <0|1>
     target_gamma <token>              VERBATIM: gamut_matrix_output's gexp test
                                       compares case-sensitively
     target_gamut <token>              informational; the matrix itself is below
     white_y / chromatic_white_y <d>   as gamut_matrix_output reads them
     node_white_y <d>                  target_xyz_for_node's resolved node white
     black <d x3>
     gamut_rgb2xyz <d x9>              rgb_to_xyz_matrix_for_gamut, row-major
     seed matrix | solve
     gamut_drive_matrix <d x9>         required iff seed matrix
     peak_inverse <d x9>               required iff seed solve
     peak_y <d x3>                     red, green, blue
     contrib <ch> <n>                  required iff seed solve; n lines of
                                       <level> <X> <Y> <Z>, ASCENDING
     chroma_luma_comp <0|1> <d>
     mid_sat_blend <0|1> <d>
     white_axis <n>                    n lines of <level> <X> <Y> <Z>, ASCENDING;
                                       present iff the model carries a white axis
     ramp <ch> <n>                     n lines of <level_frac> <X> <Y> <Z>,
                                       ASCENDING; all three channels required
     nonadd <m>                        m lines of <fr> <fg> <fb> <dX> <dY> <dZ>
                                       in fm_nonadd_samples ARRAY ORDER -- the
                                       IDW accumulation is order-dependent, so
                                       re-sorting here would break bit parity
     end

   RESPONSE (stdout)
     PGLUT3D 1 ok
     codes <N>                         N = 3*size^3
     <u16> ...                         N decimals in [0,4095], 24 per line, in
                                       node order, channels R,G,B per node
     end
   On any failure: `PGLUT3D 1 error <reason>` and a non-zero exit. */

static char line[65536];

static int rdline(void){
 if(!fgets(line,sizeof line,stdin)) return 0;
 return 1;
}

/* strtod over exactly n fields; anything non-numeric or non-finite is fatal.
   Perl writes every double with %.17g, which is round-trip exact for binary64. */
static void parse_doubles(const char *s,int n,double *out,const char *what){
 int i;
 char *end;
 for(i=0;i<n;i++){
  double v;
  end=NULL;
  v=strtod(s,&end);
  if(end==s) fail(what);
  if(!isfinite(v)) fail(what);
  out[i]=v;
  s=end;
 }
}

static void rdvals(int n,double *out,const char *what){
 if(!rdline()) fail(what);
 parse_doubles(line,n,out,what);
}

static void read_block(samp *dst,int n,const char *what){
 int i;
 for(i=0;i<n;i++){
  double v[4];
  rdvals(4,v,what);
  dst[i].lv=v[0];
  dst[i].xyz[0]=v[1]; dst[i].xyz[1]=v[2]; dst[i].xyz[2]=v[3];
 }
}

/* Advance past one whitespace-delimited token, so nesting the call steps over
   a leading integer field before strtod picks up the doubles behind it. */
static const char *after_key(const char *s){
 while(*s==' ' || *s=='\t') s++;
 while(*s && *s!=' ' && *s!='\t' && *s!='\n') s++;
 return s;
}

static void read_request(void){
 char key[64];
 int i,ver=0;
 if(!rdline()) fail("empty-request");
 if(sscanf(line,"PGLUT3D %d",&ver) != 1) fail("bad-magic");
 if(ver != PROTO_VERSION) fail("bad-version");
 while(rdline()){
  if(sscanf(line,"%63s",key) != 1) continue;
  if(!strcmp(key,"end")) return;
  else if(!strcmp(key,"size")){ if(sscanf(line,"%*s %d",&g_size)!=1) fail("size"); }
  else if(!strcmp(key,"order")){
   char v[32];
   if(sscanf(line,"%*s %31s",v)!=1) fail("order");
   if(!strcmp(v,"r_slowest")) g_order=1;
   else if(!strcmp(v,"r_fastest")) g_order=0;
   else fail("order");
  }
  else if(!strcmp(key,"neutral_axis_identity")){ if(sscanf(line,"%*s %d",&g_neutral_identity)!=1) fail("neutral_axis_identity"); }
  else if(!strcmp(key,"neutral_neighborhood")){ if(sscanf(line,"%*s %d",&g_neutral_nbhd)!=1) fail("neutral_neighborhood"); }
  else if(!strcmp(key,"target_gamma")){
   if(sscanf(line,"%*s %31s",g_gamma_raw)!=1) fail("target_gamma");
   for(i=0;g_gamma_raw[i];i++) g_gamma[i]=(g_gamma_raw[i]>='A'&&g_gamma_raw[i]<='Z')?(g_gamma_raw[i]+32):g_gamma_raw[i];
   g_gamma[i]='\0';
  }
  else if(!strcmp(key,"target_gamut")) continue;      /* informational; the matrix is shipped */
  else if(!strcmp(key,"white_y")) parse_doubles(after_key(line),1,&g_white_y,"white_y");
  else if(!strcmp(key,"chromatic_white_y")) parse_doubles(after_key(line),1,&g_chroma_white_y,"chromatic_white_y");
  else if(!strcmp(key,"node_white_y")) parse_doubles(after_key(line),1,&g_node_white_y,"node_white_y");
  else if(!strcmp(key,"black")) parse_doubles(after_key(line),3,g_black,"black");
  else if(!strcmp(key,"gamut_rgb2xyz")) parse_doubles(after_key(line),9,&g_gm[0][0],"gamut_rgb2xyz");
  else if(!strcmp(key,"gamut_drive_matrix")) parse_doubles(after_key(line),9,&g_drive[0][0],"gamut_drive_matrix");
  else if(!strcmp(key,"peak_inverse")) parse_doubles(after_key(line),9,&g_peak_inverse[0][0],"peak_inverse");
  else if(!strcmp(key,"peak_y")) parse_doubles(after_key(line),3,g_peak_y,"peak_y");
  else if(!strcmp(key,"seed")){
   char v[32];
   if(sscanf(line,"%*s %31s",v)!=1) fail("seed");
   if(!strcmp(v,"matrix")) g_seed_matrix=1;
   else if(!strcmp(v,"solve")) g_seed_matrix=0;
   else fail("seed");
  }
  else if(!strcmp(key,"chroma_luma_comp")){
   double v[1];
   if(sscanf(line,"%*s %d",&g_clc)!=1) fail("chroma_luma_comp");
   parse_doubles(after_key(after_key(line)),1,v,"chroma_luma_comp");
   g_clc_s=v[0];
  }
  else if(!strcmp(key,"mid_sat_blend")){
   double v[1];
   if(sscanf(line,"%*s %d",&g_msb)!=1) fail("mid_sat_blend");
   parse_doubles(after_key(after_key(line)),1,v,"mid_sat_blend");
   g_msb_s=v[0];
  }
  else if(!strcmp(key,"white_axis")){
   if(sscanf(line,"%*s %d",&g_nwax)!=1) fail("white_axis");
   if(g_nwax < 0 || g_nwax > MAXLVL) fail("white_axis-count");
   read_block(g_wax,g_nwax,"white_axis");
   g_have_wax=1;
  }
  else if(!strcmp(key,"ramp")){
   int ch,n;
   if(sscanf(line,"%*s %d %d",&ch,&n)!=2) fail("ramp");
   if(ch < 0 || ch > 2 || n < 1 || n > MAXRAMP) fail("ramp-count");
   g_nramp[ch]=n;
   read_block(g_ramp[ch],n,"ramp");
  }
  else if(!strcmp(key,"contrib")){
   int ch,n;
   if(sscanf(line,"%*s %d %d",&ch,&n)!=2) fail("contrib");
   if(ch < 0 || ch > 2 || n < 0 || n > MAXLVL) fail("contrib-count");
   g_ncontrib[ch]=n;
   read_block(g_contrib[ch],n,"contrib");
  }
  else if(!strcmp(key,"nonadd")){
   if(sscanf(line,"%*s %d",&g_nna)!=1) fail("nonadd");
   if(g_nna < 0 || g_nna > 4000000) fail("nonadd-count");
   g_naf=malloc(sizeof(double)*3*(g_nna?g_nna:1));
   g_nad=malloc(sizeof(double)*3*(g_nna?g_nna:1));
   if(!g_naf || !g_nad) fail("nonadd-alloc");
   for(i=0;i<g_nna;i++){
    double v[6];
    rdvals(6,v,"nonadd");
    g_naf[i][0]=v[0]; g_naf[i][1]=v[1]; g_naf[i][2]=v[2];
    g_nad[i][0]=v[3]; g_nad[i][1]=v[4]; g_nad[i][2]=v[5];
   }
  }
  else fail("unknown-directive");
 }
 fail("truncated-request");
}

static void validate_request(void){
 int ch;
 if(g_size < 2 || g_size > MAXNODE) fail("size-range");
 if(g_nna < 0) fail("missing-nonadd");
 for(ch=0;ch<3;ch++) if(g_nramp[ch] < 1) fail("missing-ramp");
 if(g_seed_matrix < 0) fail("missing-seed");
 if(!g_seed_matrix) for(ch=0;ch<3;ch++) if(g_ncontrib[ch] < 0) fail("missing-contrib");
}

static void check_gates(void){
 if(g_min_conv < GATE_CONV) fail("gate-convergence-margin");
 if(g_min_idw < GATE_IDW) fail("gate-idw-margin");
 if(g_min_det < GATE_DET) fail("gate-determinant-margin");
}

int main(int argc,char **argv){
 int i,ax0,ax1,ax2,total,idx=0,margins=0,nogate=0;
 unsigned short *out;
 /* --no-gate is for the parity harness only: it reports the branch-cliff
    margins without refusing the cube, so a divergence can be characterised
    rather than merely rejected. Never pass it from the worker. */
 for(i=1;i<argc;i++){
  if(!strcmp(argv[i],"--margins")) margins=1;
  else if(!strcmp(argv[i],"--no-gate")) nogate=1;
  else fail("bad-argument");
 }
 read_request();
 validate_request();
 total=3*g_size*g_size*g_size;
 out=malloc(sizeof(unsigned short)*total);
 if(!out) fail("out-alloc");
 /* r_slowest fills r,g,b outer->inner (.cube); r_fastest fills b,g,r (LG). */
 for(ax0=0;ax0<g_size;ax0++){
  for(ax1=0;ax1<g_size;ax1++){
   for(ax2=0;ax2<g_size;ax2++){
    double o[3];
    int r,g,b,c,neutral;
    if(g_order){ r=ax0; g=ax1; b=ax2; } else { b=ax0; g=ax1; r=ax2; }
    neutral=node_output_pct(r,g,b,g_size,o);
    for(c=0;c<3;c++){
     double q;
     if(!isfinite(o[c])) fail("non-finite-node");
     if(!neutral) margin_note(o[c],r,g,b);
     q=clampd(o[c],0,100)*4095/100+0.5;
     out[idx++]=(unsigned short)(int)q;
    }
   }
  }
 }
 /* Reported before the gates so a refusal still leaves its reason in the log. */
 fprintf(stderr,"pgen_lut_solve: %d^3 nodes=%ld iters=%ld trials=%ld accept=%.3e conv=%.3e idw=%.3e det=%.3e quant=%.3e\n",
  g_size,g_quant_n,g_iters,g_trials,g_min_accept,g_min_conv,g_min_idw,g_min_det,g_min_quant);
 if(!nogate) check_gates();
 if(margins){
  fprintf(stderr,"pgen_lut_solve: worst quantise margin %.3e at node %d,%d,%d over %ld solved values\n",
   g_min_quant,g_quant_node[0],g_quant_node[1],g_quant_node[2],g_quant_n);
  for(i=0;i<8;i++) fprintf(stderr,"  within 1e-%d of the cut: %ld\n",i,g_quant_hist[i]);
 }
 printf("PGLUT3D %d ok\ncodes %d\n",PROTO_VERSION,total);
 for(i=0;i<total;i++) printf("%u%c",out[i],((i%24)==23 || i==total-1) ? '\n' : ' ');
 printf("end\n");
 return 0;
}

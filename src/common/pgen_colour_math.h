#ifndef PGEN_COLOUR_MATH_H
#define PGEN_COLOUR_MATH_H

/* Shared C99 colour maths for native PGenerator+ components.
 *
 * Keep the expressions explicit. The LUT solver disables contraction and
 * depends on this operation order for byte parity with the Perl reference.
 */

#include <math.h>

#define PGEN_PQ_M1 (2610.0/16384.0)
#define PGEN_PQ_M2 (2523.0/32.0)
#define PGEN_PQ_C1 (3424.0/4096.0)
#define PGEN_PQ_C2 (2413.0/128.0)
#define PGEN_PQ_C3 (2392.0/128.0)
#define PGEN_BRADFORD_MATRIX_INITIALIZER \
    {{0.8951,0.2664,-0.1614}, \
     {-0.7502,1.7135,0.0367}, \
     {0.0389,-0.0685,1.0296}}

static inline double pgen_clamp(double value,double lower,double upper)
{
    if(value<lower) return lower;
    if(value>upper) return upper;
    return value;
}

static inline double pgen_pq_decode_normalized(double signal)
{
    double powered,denominator,linear;
    signal=pgen_clamp(signal,0.0,1.0);
    powered=pow(signal,1.0/PGEN_PQ_M2);
    denominator=PGEN_PQ_C2-PGEN_PQ_C3*powered;
    if(denominator<=0.0) return 0.0;
    linear=(powered-PGEN_PQ_C1)/denominator;
    if(linear<0.0) linear=0.0;
    return pgen_clamp(pow(linear,1.0/PGEN_PQ_M1),0.0,1.0);
}

static inline double pgen_pq_decode_nits(double signal)
{
    double powered=pgen_clamp(signal,0.0,1.0);
    double denominator,ratio;
    powered=pow(powered,1.0/PGEN_PQ_M2);
    denominator=fmax(PGEN_PQ_C2-PGEN_PQ_C3*powered,1e-12);
    ratio=fmax(powered-PGEN_PQ_C1,0.0)/denominator;
    return 10000.0*pow(ratio,1.0/PGEN_PQ_M1);
}

static inline double pgen_pq_encode_linear(double linear)
{
    double powered=pow(fmax(0.0,linear),PGEN_PQ_M1);
    return pow((PGEN_PQ_C1+PGEN_PQ_C2*powered)
               /(1.0+PGEN_PQ_C3*powered),PGEN_PQ_M2);
}

static inline double pgen_matrix3_determinant(const double matrix[3][3])
{
    double a=matrix[0][0],b=matrix[0][1],c=matrix[0][2];
    double d=matrix[1][0],e=matrix[1][1],f=matrix[1][2];
    double g=matrix[2][0],h=matrix[2][1],i=matrix[2][2];
    return a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g);
}

static inline int pgen_matrix3_inverse(const double matrix[3][3],
                                       double output[3][3],
                                       double tolerance,
                                       double *determinant_out)
{
    double a=matrix[0][0],b=matrix[0][1],c=matrix[0][2];
    double d=matrix[1][0],e=matrix[1][1],f=matrix[1][2];
    double g=matrix[2][0],h=matrix[2][1],i=matrix[2][2];
    double determinant=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g);
    double inverse;
    if(determinant_out) *determinant_out=determinant;
    if(fabs(determinant)<tolerance) return 0;
    inverse=1.0/determinant;
    output[0][0]=(e*i-f*h)*inverse;
    output[0][1]=(c*h-b*i)*inverse;
    output[0][2]=(b*f-c*e)*inverse;
    output[1][0]=(f*g-d*i)*inverse;
    output[1][1]=(a*i-c*g)*inverse;
    output[1][2]=(c*d-a*f)*inverse;
    output[2][0]=(d*h-e*g)*inverse;
    output[2][1]=(b*g-a*h)*inverse;
    output[2][2]=(a*e-b*d)*inverse;
    return 1;
}

/* Some ICC paths historically divide each cofactor directly. Keep that
 * reduction policy explicit because multiply-by-reciprocal can move the last
 * bit and eventually cross a 16-bit table quantisation boundary. */
static inline int pgen_matrix3_inverse_divide(const double matrix[3][3],
                                              double output[3][3],
                                              double tolerance)
{
    double a=matrix[0][0],b=matrix[0][1],c=matrix[0][2];
    double d=matrix[1][0],e=matrix[1][1],f=matrix[1][2];
    double g=matrix[2][0],h=matrix[2][1],i=matrix[2][2];
    double determinant=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g);
    if(fabs(determinant)<tolerance) return 0;
    output[0][0]=(e*i-f*h)/determinant;
    output[0][1]=(c*h-b*i)/determinant;
    output[0][2]=(b*f-c*e)/determinant;
    output[1][0]=(f*g-d*i)/determinant;
    output[1][1]=(a*i-c*g)/determinant;
    output[1][2]=(c*d-a*f)/determinant;
    output[2][0]=(d*h-e*g)/determinant;
    output[2][1]=(b*g-a*h)/determinant;
    output[2][2]=(a*e-b*d)/determinant;
    return 1;
}

#endif

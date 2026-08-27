#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "src/common/pgen_colour_math.h"

int main(int argc,char **argv)
{
    if(argc==3 && !strcmp(argv[1],"encode")) {
        double nits=strtod(argv[2],NULL);
        printf("%.17g\n",pgen_pq_encode_linear(
               pgen_clamp(nits,0.0,10000.0)/10000.0));
        return 0;
    }
    if(argc==3 && !strcmp(argv[1],"decode")) {
        printf("%.17g\n",pgen_pq_decode_nits(strtod(argv[2],NULL)));
        return 0;
    }
    if(argc==11 && !strcmp(argv[1],"inverse")) {
        double matrix[3][3],inverse[3][3];
        int index;
        for(index=0;index<9;index++) matrix[index/3][index%3]=strtod(argv[index+2],NULL);
        if(!pgen_matrix3_inverse_divide(matrix,inverse,1e-12)) return 2;
        for(index=0;index<9;index++)
            printf(index==8 ? "%.17g\n" : "%.17g ",inverse[index/3][index%3]);
        return 0;
    }
    return 64;
}

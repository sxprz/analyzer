// PARAM: --set ana.activated "['base','threadid','threadflag','term','mallocWrapper']" --enable dbg.debug --enable ana.int.interval --set solver slr3 --set ana.base.privatization none

/*#include "stdio.h"*/

int main(){
    int i = 0;
    int j = 0;
    int t = 0;

    t=0;
    while (i < 5) {
        i++;
        t=0;
        while (j < 10) {
            j++;
            t=0;
        }
        t=0;
        /* j = 3; */
    }
    t=0;

    /* while (i < 5) { */
    /*     i++; */
    /*     if(i%2) continue; */
    /*     j += i; */
    /* } */

    /* for(i=0; i<5; i++){ */
    /*     if(i%2) continue; */
    /*     j += i; */
    /* } */
}
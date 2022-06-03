// SKIP PARAM: --set ana.activated "['base','threadid','threadflag','escape','fmode', 'OSEK', 'OSEK2', 'stack_trace_set','mallocWrapper']" --set ana.osek.oil 05-private_intervals.oil --set ana.int.interval true --set ana.int.def_exc false --set solver new --set ana.osek.taskprefix function_of_ --set ana.osek.isrprefix function_of_

int x = 0;
// int y;
int z = 0;
// int t;

ISR( i2 ) {
   GetResource(r2);
   z = 0;
   assert(z == 0); //
   ReleaseResource(r2);
   return;
}

ISR( i1 ) {
   GetResource(r1);
   if (x >0) {
     x--;
   }
   assert(x >= 0);
   ReleaseResource(r1);
   return;
}

ISR( i0 ) {
   GetResource(r1);
   x++;
   if (x >16) {
     x=0;
   }
   assert(x <= 16);
   ReleaseResource(r1);
   return;
}

TASK(t) {
   GetResource(r2);
   x = 0;
   z = 0;
   ReleaseResource(r2);
   z=1;
//    assert(x <= 16); //
   assert(x >= 0); //
   assert(z <= 1); //
   assert(z >= 0); //
   return;
}
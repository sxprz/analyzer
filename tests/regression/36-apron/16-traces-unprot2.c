// SKIP PARAM: --set ana.activated[+] apron --set ana.path_sens[+] threadflag --enable ana.sv-comp.functions
extern int __VERIFIER_nondet_int();

#include <pthread.h>
#include <assert.h>

int g;

void *t_fun(void *arg) {
  return NULL;
}

int main(void) {
  int x = __VERIFIER_nondet_int(); // rand
  int y = __VERIFIER_nondet_int(); //rand
  int r = __VERIFIER_nondet_int(); //rand

  pthread_t id;
  pthread_create(&id, NULL, t_fun, NULL);

  g = r;

  x = g;
  y = g;
  __goblint_check(x == y); // TODO (like 13/66)
  return 0;
}

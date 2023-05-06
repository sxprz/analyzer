//PARAM: --enable modular --set ana.activated[+] "'modular_queries'" --set ana.activated[+] "'is_modular'" --set ana.activated[+] "'written'" --set ana.activated[+] "'used_globals'"
#include<goblint.h>
#include<stdlib.h>

int *g;

// Check that modular analysis treats reads from globals soundly
void read_global(int** i){ // i may point to g
	int z;
	int *p = &z;

	if(i == NULL){
		return;
	}
	__goblint_check(g == *i); //UNKNOWN!

	__goblint_check(p != g);
	__goblint_check(p != *i);

	int *j = malloc(sizeof(int));
	*i = j;
	__goblint_check(g == j); //UNKNOWN!

	int *k = g;
	__goblint_check(k == j); //UNKNOWN!
}

// Check that modular analysis treats writes to globals soundly
void write_global(int** i){ // i may point to g
	int z;
	int *p = &z;

	if(i == NULL){
		return;
	}

	__goblint_check(g == *i); //UNKNOWN!

	__goblint_check(p != g);
	__goblint_check(p != *i);

	int *j = malloc(sizeof(int));
	g = j;

	__goblint_check(g == j); //UNKNOWN!

	int *k = g;
	__goblint_check(k == j); //UNKNOWN!
}

// // Example main
// int main(){
// 	int x[2] = {0, 1};
// 	int *p[2] = {&x[0], &x[1]};
// 	g = x;
// 	read_global(&g);
// 	write_global(&g);
// 	return 0;
// }
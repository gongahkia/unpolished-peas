#ifndef UNPOLISHED_PEAS_FREESTANDING_STDLIB_H
#define UNPOLISHED_PEAS_FREESTANDING_STDLIB_H

typedef __SIZE_TYPE__ size_t;

void *malloc(size_t size);
void *realloc(void *pointer, size_t size);
void free(void *pointer);

#endif

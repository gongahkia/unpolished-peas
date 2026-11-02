#ifndef UNPOLISHED_PEAS_FREESTANDING_STRING_H
#define UNPOLISHED_PEAS_FREESTANDING_STRING_H

typedef __SIZE_TYPE__ size_t;

void *memcpy(void *destination, const void *source, size_t size);
void *memset(void *destination, int value, size_t size);
int memcmp(const void *left, const void *right, size_t size);
size_t strlen(const char *value);

#endif

#ifndef YANBI_RUST_BRIDGE_H
#define YANBI_RUST_BRIDGE_H
#include <stdint.h>
char *yanbi_analyze(const char *input);
void yanbi_free(char *output);
#endif

#ifndef PHP_CFWPARK_H
#define PHP_CFWPARK_H

/* A static build generates an include of this header into main/internal_functions*.c and needs the
 * module pointer from it. It must exist BEFORE configure runs: PHP_NEW_EXTENSION emits the include
 * only if it finds the header then, and without it the link fails on an undeclared
 * phpext_cfwpark_ptr. A phpize build never asks for one, which is why it did not exist at first. */
extern zend_module_entry cfwpark_module_entry;
#define phpext_cfwpark_ptr &cfwpark_module_entry

#endif

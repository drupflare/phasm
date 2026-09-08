PHP_ARG_ENABLE([cfwpark], [whether to enable the cfw park], [--enable-cfwpark], [no])

if test "$PHP_CFWPARK" != "no"; then
  PHP_NEW_EXTENSION(cfwpark, cfwpark.c, $ext_shared)
fi

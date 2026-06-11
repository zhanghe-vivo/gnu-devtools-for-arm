#undef TARGET_OS_CPP_BUILTINS
#define TARGET_OS_CPP_BUILTINS()		\
    do {					\
	builtin_define ("__fv__");		\
	builtin_define ("__USE_INIT_FINI__");	\
	builtin_assert ("system=fv");	\
	TARGET_BPABI_CPP_BUILTINS();    	\
    } while (0)

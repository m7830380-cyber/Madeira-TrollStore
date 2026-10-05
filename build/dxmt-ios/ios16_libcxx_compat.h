// Force-included into DXMT's C++ (build.sh). libc++ marks the floating-point
// std::to_chars overloads, which std::format uses, as introduced in iOS 16.3;
// the app target defines them for iOS 16.0-16.2 (app/Madeira/iOS16LibcxxCompat.cpp).
// Only this one availability gate is lifted:
// every other libc++ availability check stays on, so anything else newer than
// the deployment target still falls back or fails to compile.
#pragma once
#ifdef __cplusplus
#include <__config>
#undef _LIBCPP_AVAILABILITY_HAS_TO_CHARS_FLOATING_POINT
#define _LIBCPP_AVAILABILITY_HAS_TO_CHARS_FLOATING_POINT 1
#undef _LIBCPP_AVAILABILITY_TO_CHARS_FLOATING_POINT
#define _LIBCPP_AVAILABILITY_TO_CHARS_FLOATING_POINT
#endif

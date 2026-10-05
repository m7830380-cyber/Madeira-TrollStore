// iOS 16.0-16.2: libc++.dylib exports the floating-point std::to_chars
// overloads only from iOS 16.3, and std::format (DXMT's logging) calls them.
// These definitions are linked into the app, so the static link binds to them
// instead of the system library and nothing is left to resolve at launch.
// Built with _LIBCPP_DISABLE_AVAILABILITY, like the DXMT objects that use them.
#include <charconv>
#include <cstdio>
#include <cstring>
#include <system_error>

namespace {

template <typename T>
std::to_chars_result put(char *first, char *last, const char *fmt, int precision, T value) {
    char buf[512];
    int n = precision >= 0 ? snprintf(buf, sizeof(buf), fmt, precision, (long double)value)
                           : snprintf(buf, sizeof(buf), fmt, (long double)value);
    if (n < 0 || n >= (int)sizeof(buf) || n > last - first)
        return {last, std::errc::value_too_large};
    memcpy(first, buf, (size_t)n);
    return {first + n, std::errc{}};
}

template <typename T>
std::to_chars_result shortest(char *first, char *last, T value) {
    // Round-trip digits for the type, %g layout.
    const int digits = sizeof(T) == sizeof(float) ? 9 : 17;
    return put(first, last, "%.*Lg", digits, value);
}

template <typename T>
std::to_chars_result formatted(char *first, char *last, T value, std::chars_format fmt, int precision) {
    switch (fmt) {
    case std::chars_format::scientific: return precision < 0 ? put(first, last, "%Le", -1, value) : put(first, last, "%.*Le", precision, value);
    case std::chars_format::fixed:      return precision < 0 ? put(first, last, "%Lf", -1, value) : put(first, last, "%.*Lf", precision, value);
    case std::chars_format::hex:        return precision < 0 ? put(first, last, "%La", -1, value) : put(first, last, "%.*La", precision, value);
    default:                            return precision < 0 ? shortest(first, last, value) : put(first, last, "%.*Lg", precision, value);
    }
}

} // namespace

namespace std {
inline namespace __1 {

to_chars_result to_chars(char *f, char *l, float v) { return shortest(f, l, v); }
to_chars_result to_chars(char *f, char *l, double v) { return shortest(f, l, v); }
to_chars_result to_chars(char *f, char *l, long double v) { return shortest(f, l, v); }
to_chars_result to_chars(char *f, char *l, float v, chars_format c) { return formatted(f, l, v, c, -1); }
to_chars_result to_chars(char *f, char *l, double v, chars_format c) { return formatted(f, l, v, c, -1); }
to_chars_result to_chars(char *f, char *l, long double v, chars_format c) { return formatted(f, l, v, c, -1); }
to_chars_result to_chars(char *f, char *l, float v, chars_format c, int p) { return formatted(f, l, v, c, p); }
to_chars_result to_chars(char *f, char *l, double v, chars_format c, int p) { return formatted(f, l, v, c, p); }
to_chars_result to_chars(char *f, char *l, long double v, chars_format c, int p) { return formatted(f, l, v, c, p); }

} // namespace __1
} // namespace std

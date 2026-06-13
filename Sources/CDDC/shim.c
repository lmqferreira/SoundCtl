// Intentionally minimal. CDDC only re-exports private IOAVService
// declarations from include/CDDC.h; the symbols resolve against IOKit
// at link time. This translation unit exists so SwiftPM treats CDDC
// as a buildable C target.
#include "CDDC.h"

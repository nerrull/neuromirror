// core_frame.h — a handful of per-frame core helpers, still defined in
// main.mm, that dev_tools.mm and panel.mm need to call.
//
// These stay in main.mm on purpose (see the split's plan notes): they are
// the live app's own frame-source/tracking/show logic, not dev-tooling or
// UI. Only their visibility changes here -- from `static` (main.mm-only) to
// plain extern-linkage functions declared in this small, app-internal
// header, so the definitions do not have to move.
#pragma once

#include <string>
#include <vector>

bool  LoadImageRGB(const char* path, int w, int h,
                    std::vector<float>& out, std::string& err);
bool  LoadPhotoSource(const char* path, std::string& err);
float W0RampT(double now);
bool  ShowFacePresent();
bool  ShowFitConverged();
bool  HaveCrop();
float PlaceScale();
bool  SourceReady();

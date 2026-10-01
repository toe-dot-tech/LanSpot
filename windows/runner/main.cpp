#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

// Declares SetCurrentProcessExplicitAppUserModelID. It lives in shell32's
// shobjidl.h, which windows.h does not pull in, so it has to be named here.
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Set an explicit AppUserModelID before creating any windows.
  //
  // Without this, an unpackaged app is identified by its full executable path,
  // so the taskbar entry, grouping, and any pinned-icon behaviour all silently
  // change whenever the binary is moved or renamed. Declaring it here keeps the
  // identity stable at "LanSpot" and lets the UI show a friendly name instead
  // of the raw package identity.
  ::SetCurrentProcessExplicitAppUserModelID(L"LanSpot");

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1180, 820);
  if (!window.Create(L"LanSpot", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

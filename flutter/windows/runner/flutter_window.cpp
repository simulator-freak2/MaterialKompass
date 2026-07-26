#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winspool.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kLabelPrinterChannel[] = "materialkompass/label_printer";

std::string WideToUtf8(const wchar_t* value) {
  if (value == nullptr) {
    return {};
  }
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) {
    return {};
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr,
                      nullptr);
  result.resize(static_cast<size_t>(size - 1));
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (size <= 1) {
    return {};
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  result.resize(static_cast<size_t>(size - 1));
  return result;
}

flutter::EncodableList EnumeratePrinters() {
  constexpr DWORD flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
  DWORD required = 0;
  DWORD count = 0;
  EnumPrintersW(flags, nullptr, 4, nullptr, 0, &required, &count);
  flutter::EncodableList result;
  if (required == 0) {
    return result;
  }

  std::vector<BYTE> buffer(required);
  if (!EnumPrintersW(flags, nullptr, 4, buffer.data(), required, &required,
                     &count)) {
    return result;
  }
  const auto* printers =
      reinterpret_cast<const PRINTER_INFO_4W*>(buffer.data());
  for (DWORD index = 0; index < count; ++index) {
    const auto name = WideToUtf8(printers[index].pPrinterName);
    if (!name.empty()) {
      result.emplace_back(name);
    }
  }
  return result;
}

bool SendRawPrint(const std::string& printer_name,
                  const std::vector<uint8_t>& bytes,
                  std::string* error) {
  auto wide_name = Utf8ToWide(printer_name);
  HANDLE printer = nullptr;
  if (wide_name.empty() ||
      !OpenPrinterW(wide_name.data(), &printer, nullptr)) {
    *error = "Die Windows-Druckerwarteschlange konnte nicht geöffnet werden.";
    return false;
  }

  wchar_t document_name[] = L"MaterialKompass Etikett";
  wchar_t data_type[] = L"RAW";
  DOC_INFO_1W document{document_name, nullptr, data_type};
  const DWORD job = StartDocPrinterW(printer, 1,
                                     reinterpret_cast<LPBYTE>(&document));
  if (job == 0) {
    ClosePrinter(printer);
    *error = "Der Windows-Druckauftrag konnte nicht gestartet werden.";
    return false;
  }

  bool success = StartPagePrinter(printer) != FALSE;
  DWORD written = 0;
  if (success) {
    success = WritePrinter(printer,
                           const_cast<uint8_t*>(bytes.data()),
                           static_cast<DWORD>(bytes.size()), &written) != FALSE &&
              written == bytes.size();
    EndPagePrinter(printer);
  }
  EndDocPrinter(printer);
  ClosePrinter(printer);
  if (!success) {
    *error = "Windows konnte die ZPL-Daten nicht vollständig spoolen.";
  }
  return success;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto label_printer_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kLabelPrinterChannel,
          &flutter::StandardMethodCodec::GetInstance());
  label_printer_channel->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "listSystemPrinters") {
          result->Success(flutter::EncodableValue(EnumeratePrinters()));
          return;
        }
        if (call.method_name() == "sendSystemPrint") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Druckdaten fehlen.");
            return;
          }
          const auto printer_entry =
              arguments->find(flutter::EncodableValue("printerName"));
          const auto bytes_entry =
              arguments->find(flutter::EncodableValue("bytes"));
          if (printer_entry == arguments->end() ||
              bytes_entry == arguments->end()) {
            result->Error("invalid_arguments",
                          "Druckername oder Druckdaten fehlen.");
            return;
          }
          const auto* printer_name =
              std::get_if<std::string>(&printer_entry->second);
          const auto* bytes =
              std::get_if<std::vector<uint8_t>>(&bytes_entry->second);
          if (printer_name == nullptr || bytes == nullptr || bytes->empty()) {
            result->Error("invalid_arguments",
                          "Druckername oder Druckdaten sind ungültig.");
            return;
          }
          std::string error;
          if (!SendRawPrint(*printer_name, *bytes, &error)) {
            result->Error("print_failed", error);
            return;
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  label_printer_channel_ = std::move(label_printer_channel);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    label_printer_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

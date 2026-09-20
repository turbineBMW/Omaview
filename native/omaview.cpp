#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/debug/HyprCtl.hpp>

#include <hyprland/src/protocols/LayerShell.hpp>

#include <chrono>
#include <stdexcept>

namespace {
constexpr auto NAMESPACE = "omarchy-omaview";
std::vector<CHyprSignalListener> listeners;
std::string lastGeometry;
std::chrono::steady_clock::time_point lastCheck;

PHLLS overview() {
    for (const auto& layer : Desktop::layerState()->layers()) {
        // Only the nonexclusive overview participates. Other shell panels and
        // secure surfaces keep Hyprland's normal focus policy.
        if (layer->m_mapped && layer->m_namespace == NAMESPACE && layer->m_layerSurface && layer->m_layerSurface->m_current.interactivity == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND)
            return layer;
    }
    return nullptr;
}

void routeKeyboard() {
    if (g_pSessionLockManager->isSessionLocked() || !g_pInputManager->m_exclusiveLSes.empty() || g_pSeatManager->m_seatGrab)
        return;
    const auto layer = overview();
    if (!layer)
        return;

    // A layer can receive keyboard input without changing the active WINDOW.
    // This runs before Hyprland processes binds. A bind is still dispatched by
    // Hyprland against its real active window; unbound typing reaches QML.
    Desktop::focusState()->rawSurfaceFocus(layer->wlSurface()->resource());
}

void geometryChanged() {
    if (!overview()) {
        lastGeometry.clear();
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now - lastCheck < std::chrono::milliseconds(16))
        return;
    lastCheck = now;

    // IPC has no geometry event. Observe compositor layout output, never user
    // actions. Match the goal coordinates exported by `hyprctl clients`.
    std::string geometry;
    for (const auto& window : Desktop::windowState()->windows()) {
        if (!window->m_isMapped || window->isHidden())
            continue;
        const auto pos = window->position(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        const auto size = window->size(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        geometry += std::format("{:x}:{},{},{},{};", reinterpret_cast<uintptr_t>(window.get()),
                                static_cast<int>(pos.x), static_cast<int>(pos.y),
                                static_cast<int>(size.x), static_cast<int>(size.y));
    }
    if (geometry != lastGeometry) {
        lastGeometry = std::move(geometry);
        g_pEventManager->postEvent({"omaview", "geometry"});
    }
}
}

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    if (std::string_view(__hyprland_api_get_hash()) != __hyprland_api_get_client_hash())
        throw std::runtime_error("Omaview: installed headers do not match the running Hyprland ABI");

    // Read the standard IPC serializers in one compositor turn, so window,
    // workspace and focus data cannot come from different actions.
    if (!HyprlandAPI::registerHyprCtlCommand(handle, {"omaview-state", true,
        [](eHyprCtlOutputFormat, std::string) {
            return "{\"clients\":" + g_pHyprCtl->getReply("j/clients")
                 + ",\"monitors\":" + g_pHyprCtl->getReply("j/monitors")
                 + ",\"workspaces\":" + g_pHyprCtl->getReply("j/workspaces")
                 + ",\"activewindow\":" + g_pHyprCtl->getReply("j/activewindow") + "}";
        }}))
        throw std::runtime_error("Omaview: could not register state command");

    listeners.emplace_back(Event::bus()->m_events.input.keyboard.key.listen(
        [](const IKeyboard::SKeyEvent&, Event::SCallbackInfo&) { routeKeyboard(); }));
    // Restore the layer's keyboard surface as part of the native focus
    // notification. Waiting for the next key would put that key in the
    // wl_keyboard.enter held-key list, causing Qt to miss its first press.
    listeners.emplace_back(Event::bus()->m_events.window.active.listen(
        [](PHLWINDOW, Desktop::eFocusReason) { routeKeyboard(); }));
    listeners.emplace_back(Event::bus()->m_events.render.pre.listen(
        [](PHLMONITOR) { geometryChanged(); }));

    return {"omaview", "Native focus and geometry events for the Omaview shell", "turbinebmw", "1.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    listeners.clear();
    lastGeometry.clear();
    if (g_pEventManager)
        g_pEventManager->postEvent({"omaview", "unloaded"});
}

#include "platform_channel.h"

#include <libayatana-appindicator/app-indicator.h>

namespace {

constexpr const char kChannelName[] = "ecycloud/platform";
constexpr const char kIndicatorId[] = "ecycloud-client";
constexpr const char kIndicatorIcon[] = "com.ecycloud.client";
constexpr const char kActionKey[] = "ecycloud-action";

}  // namespace

struct _PlatformChannel {
  FlMethodChannel* channel;
  GtkWindow* window;
  AppIndicator* indicator;
  gboolean close_to_tray;
  gboolean connected;
  gboolean busy;
  gboolean system_proxy;
  gboolean tun;
};

static void update_menu(PlatformChannel* self);

static gboolean lookup_bool(FlValue* arguments, const gchar* key) {
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

static void restore_main_window(PlatformChannel* self) {
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_present(self->window);
}

static void remove_tray(PlatformChannel* self) {
  if (self->indicator == nullptr) {
    return;
  }
  app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_PASSIVE);
  g_clear_object(&self->indicator);
}

static void on_menu_item_activate(GtkMenuItem* item, gpointer user_data) {
  PlatformChannel* self = static_cast<PlatformChannel*>(user_data);
  const gchar* action = static_cast<const gchar*>(
      g_object_get_data(G_OBJECT(item), kActionKey));
  if (action == nullptr) {
    return;
  }

  if (g_strcmp0(action, "show") == 0) {
    restore_main_window(self);
    return;
  }
  if (g_strcmp0(action, "quit") == 0) {
    remove_tray(self);
    gtk_widget_destroy(GTK_WIDGET(self->window));
    return;
  }

  g_autoptr(FlValue) arguments = fl_value_new_string(action);
  fl_method_channel_invoke_method(self->channel, "tray.action", arguments,
                                  nullptr, nullptr, nullptr);
}

static void append_item(PlatformChannel* self, GtkMenuShell* menu,
                        const gchar* label, const gchar* action) {
  GtkWidget* item = gtk_menu_item_new_with_label(label);
  g_object_set_data_full(G_OBJECT(item), kActionKey, g_strdup(action), g_free);
  g_signal_connect(item, "activate", G_CALLBACK(on_menu_item_activate), self);
  gtk_menu_shell_append(menu, item);
}

// gtk_check_menu_item_set_active 会顺带发一次 activate，必须先设状态再接信号
static void append_check_item(PlatformChannel* self, GtkMenuShell* menu,
                              const gchar* label, const gchar* action,
                              gboolean checked, gboolean enabled) {
  GtkWidget* item = gtk_check_menu_item_new_with_label(label);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), checked);
  gtk_widget_set_sensitive(item, enabled);
  g_object_set_data_full(G_OBJECT(item), kActionKey, g_strdup(action), g_free);
  g_signal_connect(item, "activate", G_CALLBACK(on_menu_item_activate), self);
  gtk_menu_shell_append(menu, item);
}

static GtkWidget* build_menu(PlatformChannel* self) {
  GtkWidget* menu = gtk_menu_new();
  GtkMenuShell* shell = GTK_MENU_SHELL(menu);

  if (self->busy) {
    append_item(self, shell, "取消连接", "disconnect");
  } else if (self->connected) {
    append_item(self, shell, "断开连接", "disconnect");
  } else {
    append_item(self, shell, "连接", "connect");
  }
  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());

  // 未连接时不得占用系统代理 / TUN，菜单项禁用且不勾选
  append_check_item(self, shell, "系统代理", "system_proxy",
                    self->system_proxy, self->connected);
  append_check_item(self, shell, "TUN 模式", "tun", self->tun,
                    self->connected);

  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());
  append_item(self, shell, "显示主界面", "show");
  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());
  append_item(self, shell, "退出", "quit");

  gtk_widget_show_all(menu);
  return menu;
}

static void update_menu(PlatformChannel* self) {
  if (self->indicator == nullptr) {
    return;
  }
  app_indicator_set_menu(self->indicator, GTK_MENU(build_menu(self)));
}

// AppIndicator 只在托盘上暴露菜单，没有左键单击回调，还原窗口只能走菜单项
static void install_tray(PlatformChannel* self) {
  if (self->indicator != nullptr) {
    return;
  }
  self->indicator = app_indicator_new(kIndicatorId, kIndicatorIcon,
                                      APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_ACTIVE);
  app_indicator_set_title(self->indicator, "ECY Cloud 网络助手");
  update_menu(self);
}

static gboolean on_window_delete(GtkWidget* widget, GdkEvent* event,
                                 gpointer user_data) {
  PlatformChannel* self = static_cast<PlatformChannel*>(user_data);
  // 托盘不可用时不能吞掉关闭，否则窗口再也关不掉
  if (!self->close_to_tray || self->indicator == nullptr) {
    return FALSE;
  }
  gtk_widget_hide(widget);
  return TRUE;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  PlatformChannel* self = static_cast<PlatformChannel*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* arguments = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "tray.install") == 0) {
    install_tray(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "tray.remove") == 0) {
    remove_tray(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "tray.closeToTray") == 0) {
    self->close_to_tray = lookup_bool(arguments, "enabled");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "tray.state") == 0) {
    self->connected = lookup_bool(arguments, "connected");
    self->busy = lookup_bool(arguments, "busy");
    self->system_proxy = lookup_bool(arguments, "system_proxy");
    self->tun = lookup_bool(arguments, "tun");
    update_menu(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("应答 %s 失败: %s", method, error->message);
  }
}

PlatformChannel* platform_channel_new(FlView* view, GtkWindow* window) {
  PlatformChannel* self = g_new0(PlatformChannel, 1);
  self->window = window;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb, self,
                                            nullptr);

  g_signal_connect(window, "delete-event", G_CALLBACK(on_window_delete), self);
  return self;
}

void platform_channel_free(PlatformChannel* self) {
  if (self == nullptr) {
    return;
  }
  remove_tray(self);
  g_clear_object(&self->channel);
  g_free(self);
}

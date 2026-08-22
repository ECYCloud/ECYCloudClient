#include "platform_channel.h"

#include <algorithm>

#include <libayatana-appindicator/app-indicator.h>
#include <libsecret/secret.h>

namespace {

constexpr const char kChannelName[] = "ecycloud/platform";
constexpr const char kIndicatorId[] = "ecycloud-client";
constexpr const char kIndicatorIcon[] = "com.ecycloud.client";
constexpr const char kActionKey[] = "ecycloud-action";

const SecretSchema kRememberedSchema = {
    "com.ecycloud.client.RememberedLogin",
    SECRET_SCHEMA_NONE,
    {
        {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {nullptr, static_cast<SecretSchemaAttributeType>(0)},
    },
};

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
  gboolean mode_enabled;
  gchar* route_mode;
  gchar* label_connect;
  gchar* label_disconnect;
  gchar* label_cancel;
  gchar* label_system_proxy;
  gchar* label_tun;
  gchar* label_rule;
  gchar* label_global;
  gchar* label_direct;
  gchar* label_show;
  gchar* label_quit;
  gchar* status_tip;
  GdkPixbuf* default_icon;
  gint icon_tint;
};

static void update_menu(PlatformChannel* self);
static void apply_icons(PlatformChannel* self);
static void apply_title(PlatformChannel* self);

static const gchar* lookup_string(FlValue* arguments, const gchar* key) {
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(arguments, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

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
  if (self->default_icon != nullptr) {
    gtk_window_set_icon(self->window, self->default_icon);
  }
  self->icon_tint = -1;
}

static void on_menu_item_activate(GtkMenuItem* item, gpointer user_data) {
  PlatformChannel* self = static_cast<PlatformChannel*>(user_data);
  const gchar* action = static_cast<const gchar*>(
      g_object_get_data(G_OBJECT(item), kActionKey));
  if (action == nullptr) {
    return;
  }
  // radio 取消选中也会发 activate，只上报新选中的那项
  if (GTK_IS_RADIO_MENU_ITEM(item) &&
      !gtk_check_menu_item_get_active(GTK_CHECK_MENU_ITEM(item))) {
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

static GtkWidget* append_radio_item(GtkMenuShell* menu, GSList** group,
                                    const gchar* label, const gchar* action,
                                    gboolean enabled) {
  GtkWidget* item = gtk_radio_menu_item_new_with_label(*group, label);
  *group = gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(item));
  gtk_widget_set_sensitive(item, enabled);
  g_object_set_data_full(G_OBJECT(item), kActionKey, g_strdup(action), g_free);
  gtk_menu_shell_append(menu, item);
  return item;
}

static GtkWidget* build_menu(PlatformChannel* self) {
  GtkWidget* menu = gtk_menu_new();
  GtkMenuShell* shell = GTK_MENU_SHELL(menu);

  if (self->busy) {
    append_item(self, shell,
                self->label_cancel != nullptr ? self->label_cancel : "取消连接",
                "disconnect");
  } else if (self->connected) {
    append_item(
        self, shell,
        self->label_disconnect != nullptr ? self->label_disconnect : "断开连接",
        "disconnect");
  } else {
    append_item(self, shell,
                self->label_connect != nullptr ? self->label_connect : "连接",
                "connect");
  }
  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());

  append_check_item(
      self, shell,
      self->label_system_proxy != nullptr ? self->label_system_proxy : "系统代理",
      "system_proxy", self->system_proxy, self->connected);
  append_check_item(self, shell,
                    self->label_tun != nullptr ? self->label_tun : "TUN 模式",
                    "tun", self->tun, self->connected);

  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());
  const gchar* mode = self->route_mode != nullptr ? self->route_mode : "rule";
  const gboolean mode_global = g_strcmp0(mode, "global") == 0;
  const gboolean mode_direct = g_strcmp0(mode, "direct") == 0;
  GSList* group = nullptr;
  GtkWidget* rule_item = append_radio_item(
      shell, &group,
      self->label_rule != nullptr ? self->label_rule : "规则", "mode_rule",
      self->mode_enabled);
  GtkWidget* global_item = append_radio_item(
      shell, &group,
      self->label_global != nullptr ? self->label_global : "全局",
      "mode_global", self->mode_enabled);
  GtkWidget* direct_item = append_radio_item(
      shell, &group,
      self->label_direct != nullptr ? self->label_direct : "直连",
      "mode_direct", self->mode_enabled);
  gtk_check_menu_item_set_active(
      GTK_CHECK_MENU_ITEM(mode_direct ? direct_item
                                      : (mode_global ? global_item : rule_item)),
      TRUE);
  g_signal_connect(rule_item, "activate", G_CALLBACK(on_menu_item_activate),
                   self);
  g_signal_connect(global_item, "activate", G_CALLBACK(on_menu_item_activate),
                   self);
  g_signal_connect(direct_item, "activate", G_CALLBACK(on_menu_item_activate),
                   self);

  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());
  append_item(self, shell,
              self->label_show != nullptr ? self->label_show : "显示主界面",
              "show");
  gtk_menu_shell_append(shell, gtk_separator_menu_item_new());
  append_item(self, shell,
              self->label_quit != nullptr ? self->label_quit : "退出", "quit");

  gtk_widget_show_all(menu);
  return menu;
}

static void rgb_to_hsl(float r, float g, float b, float* h, float* s,
                       float* l) {
  const float max = std::max({r, g, b});
  const float min = std::min({r, g, b});
  *l = (max + min) / 2.f;
  if (max == min) {
    *h = 0;
    *s = 0;
    return;
  }
  const float d = max - min;
  *s = *l > 0.5f ? d / (2.f - max - min) : d / (max + min);
  if (max == r) {
    *h = (g - b) / d + (g < b ? 6.f : 0);
  } else if (max == g) {
    *h = (b - r) / d + 2.f;
  } else {
    *h = (r - g) / d + 4.f;
  }
  *h *= 60.f;
}

static float hue_to_channel(float p, float q, float t) {
  if (t < 0) {
    t += 1.f;
  }
  if (t > 1.f) {
    t -= 1.f;
  }
  if (t < 1.f / 6.f) {
    return p + (q - p) * 6.f * t;
  }
  if (t < 0.5f) {
    return q;
  }
  if (t < 2.f / 3.f) {
    return p + (q - p) * (2.f / 3.f - t) * 6.f;
  }
  return p;
}

static void hsl_to_rgb(float h, float s, float l, float* r, float* g,
                       float* b) {
  if (s == 0) {
    *r = *g = *b = l;
    return;
  }
  const float q = l < 0.5f ? l * (1.f + s) : l + s - l * s;
  const float p = 2.f * l - q;
  const float hk = h / 360.f;
  *r = hue_to_channel(p, q, hk + 1.f / 3.f);
  *g = hue_to_channel(p, q, hk);
  *b = hue_to_channel(p, q, hk - 1.f / 3.f);
}

static void hue_shift_pixbuf(GdkPixbuf* buf, float target_hue) {
  if (buf == nullptr || !gdk_pixbuf_get_has_alpha(buf) ||
      gdk_pixbuf_get_colorspace(buf) != GDK_COLORSPACE_RGB ||
      gdk_pixbuf_get_n_channels(buf) != 4) {
    return;
  }
  const int width = gdk_pixbuf_get_width(buf);
  const int height = gdk_pixbuf_get_height(buf);
  const int stride = gdk_pixbuf_get_rowstride(buf);
  guchar* pixels = gdk_pixbuf_get_pixels(buf);
  for (int y = 0; y < height; ++y) {
    guchar* row = pixels + y * stride;
    for (int x = 0; x < width; ++x) {
      guchar* p = row + x * 4;
      if (p[3] == 0) {
        continue;
      }
      float r = p[0] / 255.f;
      float g = p[1] / 255.f;
      float b = p[2] / 255.f;
      float h = 0;
      float s = 0;
      float l = 0;
      rgb_to_hsl(r, g, b, &h, &s, &l);
      if (s <= 0.12f || h < 170.f || h > 270.f) {
        continue;
      }
      float nr = 0;
      float ng = 0;
      float nb = 0;
      hsl_to_rgb(target_hue, s, l, &nr, &ng, &nb);
      p[0] = static_cast<guchar>(nr * 255.f + 0.5f);
      p[1] = static_cast<guchar>(ng * 255.f + 0.5f);
      p[2] = static_cast<guchar>(nb * 255.f + 0.5f);
    }
  }
}

static GdkPixbuf* load_source_icon(PlatformChannel* self) {
  if (self->default_icon != nullptr) {
    return self->default_icon;
  }
  GdkPixbuf* icon = gtk_window_get_icon(self->window);
  if (icon != nullptr) {
    self->default_icon = GDK_PIXBUF(g_object_ref(icon));
    return self->default_icon;
  }
  GError* error = nullptr;
  icon = gtk_icon_theme_load_icon(gtk_icon_theme_get_default(), kIndicatorIcon,
                                  48, static_cast<GtkIconLookupFlags>(0),
                                  &error);
  if (error != nullptr) {
    g_error_free(error);
  }
  self->default_icon = icon;
  return self->default_icon;
}

static void apply_icons(PlatformChannel* self) {
  const int want = self->tun ? 2 : (self->system_proxy ? 1 : 0);
  if (want == self->icon_tint) {
    return;
  }
  GdkPixbuf* source = load_source_icon(self);
  if (source == nullptr) {
    return;
  }
  GdkPixbuf* icon = gdk_pixbuf_copy(source);
  if (icon == nullptr) {
    return;
  }
  if (want != 0) {
    hue_shift_pixbuf(icon, want == 2 ? 145.f : 28.f);
  }
  gtk_window_set_icon(self->window, icon);
  if (self->indicator != nullptr) {
    const gchar* runtime = g_get_user_runtime_dir();
    if (runtime == nullptr) {
      runtime = g_get_tmp_dir();
    }
    gchar* dir = g_build_filename(runtime, "ecycloud", nullptr);
    g_mkdir_with_parents(dir, 0700);
    const char* name =
        want == 2 ? "tray-green" : (want == 1 ? "tray-orange" : "tray-default");
    gchar* path = g_build_filename(dir, name, nullptr);
    gchar* png = g_strconcat(path, ".png", nullptr);
    if (gdk_pixbuf_save(icon, png, "png", nullptr, nullptr)) {
      app_indicator_set_icon_theme_path(self->indicator, dir);
      app_indicator_set_icon(self->indicator, name);
    }
    g_free(png);
    g_free(path);
    g_free(dir);
  }
  g_object_unref(icon);
  self->icon_tint = want;
}

static void update_menu(PlatformChannel* self) {
  if (self->indicator == nullptr) {
    return;
  }
  app_indicator_set_menu(self->indicator, GTK_MENU(build_menu(self)));
}

// AppIndicator 没有 tooltip 接口，标题是各桌面唯一会当悬浮提示显示的字段
static void apply_title(PlatformChannel* self) {
  if (self->indicator == nullptr) {
    return;
  }
  g_autofree gchar* title =
      self->status_tip != nullptr
          ? g_strconcat("ECY Cloud\n", self->status_tip, nullptr)
          : g_strdup("ECY Cloud");
  app_indicator_set_title(self->indicator, title);
}

// AppIndicator 只在托盘上暴露菜单，没有左键单击回调，还原窗口只能走菜单项
static void install_tray(PlatformChannel* self) {
  if (self->indicator != nullptr) {
    return;
  }
  self->indicator = app_indicator_new(kIndicatorId, kIndicatorIcon,
                                      APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_ACTIVE);
  apply_title(self);
  update_menu(self);
  apply_icons(self);
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
    self->mode_enabled = lookup_bool(arguments, "mode_enabled");
    const gchar* connect = lookup_string(arguments, "label_connect");
    const gchar* disconnect = lookup_string(arguments, "label_disconnect");
    const gchar* cancel = lookup_string(arguments, "label_cancel");
    const gchar* system_proxy = lookup_string(arguments, "label_system_proxy");
    const gchar* tun = lookup_string(arguments, "label_tun");
    const gchar* rule = lookup_string(arguments, "label_rule");
    const gchar* global = lookup_string(arguments, "label_global");
    const gchar* direct = lookup_string(arguments, "label_direct");
    const gchar* show = lookup_string(arguments, "label_show");
    const gchar* quit = lookup_string(arguments, "label_quit");
    const gchar* route_mode = lookup_string(arguments, "route_mode");
    const gchar* status_tip = lookup_string(arguments, "status_tip");
    if (connect != nullptr) {
      g_free(self->label_connect);
      self->label_connect = g_strdup(connect);
    }
    if (disconnect != nullptr) {
      g_free(self->label_disconnect);
      self->label_disconnect = g_strdup(disconnect);
    }
    if (cancel != nullptr) {
      g_free(self->label_cancel);
      self->label_cancel = g_strdup(cancel);
    }
    if (system_proxy != nullptr) {
      g_free(self->label_system_proxy);
      self->label_system_proxy = g_strdup(system_proxy);
    }
    if (tun != nullptr) {
      g_free(self->label_tun);
      self->label_tun = g_strdup(tun);
    }
    if (rule != nullptr) {
      g_free(self->label_rule);
      self->label_rule = g_strdup(rule);
    }
    if (global != nullptr) {
      g_free(self->label_global);
      self->label_global = g_strdup(global);
    }
    if (direct != nullptr) {
      g_free(self->label_direct);
      self->label_direct = g_strdup(direct);
    }
    if (show != nullptr) {
      g_free(self->label_show);
      self->label_show = g_strdup(show);
    }
    if (quit != nullptr) {
      g_free(self->label_quit);
      self->label_quit = g_strdup(quit);
    }
    if (route_mode != nullptr) {
      g_free(self->route_mode);
      self->route_mode = g_strdup(route_mode);
    }
    if (status_tip != nullptr) {
      g_free(self->status_tip);
      self->status_tip = g_strdup(status_tip);
    }
    update_menu(self);
    apply_icons(self);
    apply_title(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "secret.protect") == 0) {
    const gchar* name = lookup_string(arguments, "name");
    const gchar* value = lookup_string(arguments, "value");
    if (name == nullptr || value == nullptr) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("argument", "缺少参数", nullptr));
    } else {
      g_autoptr(GError) store_error = nullptr;
      if (secret_password_store_sync(
              &kRememberedSchema, SECRET_COLLECTION_DEFAULT, "ECY Cloud",
              value, nullptr, &store_error, "account", name, nullptr)) {
        response = FL_METHOD_RESPONSE(
            fl_method_success_response_new(fl_value_new_string("")));
      } else {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "secret",
            store_error != nullptr ? store_error->message : "无法保护凭据",
            nullptr));
      }
    }
  } else if (g_strcmp0(method, "secret.unprotect") == 0) {
    const gchar* name = lookup_string(arguments, "name");
    if (name == nullptr) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("argument", "缺少参数", nullptr));
    } else {
      g_autoptr(GError) lookup_error = nullptr;
      gchar* password = secret_password_lookup_sync(
          &kRememberedSchema, nullptr, &lookup_error, "account", name, nullptr);
      if (password != nullptr) {
        response = FL_METHOD_RESPONSE(
            fl_method_success_response_new(fl_value_new_string(password)));
        secret_password_free(password);
      } else if (lookup_error != nullptr) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "secret", lookup_error->message, nullptr));
      } else {
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      }
    }
  } else if (g_strcmp0(method, "secret.delete") == 0) {
    const gchar* name = lookup_string(arguments, "name");
    if (name == nullptr) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("argument", "缺少参数", nullptr));
    } else {
      g_autoptr(GError) clear_error = nullptr;
      secret_password_clear_sync(&kRememberedSchema, nullptr, &clear_error,
                                 "account", name, nullptr);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
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
  self->icon_tint = -1;
  return self;
}

void platform_channel_free(PlatformChannel* self) {
  if (self == nullptr) {
    return;
  }
  remove_tray(self);
  g_clear_object(&self->channel);
  g_free(self->label_connect);
  g_free(self->label_disconnect);
  g_free(self->label_cancel);
  g_free(self->label_system_proxy);
  g_free(self->label_tun);
  g_free(self->label_rule);
  g_free(self->label_global);
  g_free(self->label_direct);
  g_free(self->label_show);
  g_free(self->label_quit);
  g_free(self->route_mode);
  g_free(self->status_tip);
  g_clear_object(&self->default_icon);
  g_free(self);
}

#ifndef RUNNER_PLATFORM_CHANNEL_H_
#define RUNNER_PLATFORM_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _PlatformChannel PlatformChannel;

PlatformChannel* platform_channel_new(FlView* view, GtkWindow* window);

void platform_channel_free(PlatformChannel* self);

G_END_DECLS

#endif  // RUNNER_PLATFORM_CHANNEL_H_

#include <GL/gl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>

int main(void) {
  Display *display = XOpenDisplay(NULL);
  if (display == NULL) {
    puts("display=unavailable");
    return 2;
  }

  int attributes[] = {GLX_RGBA, GLX_DOUBLEBUFFER, None};
  XVisualInfo *visual = glXChooseVisual(display, DefaultScreen(display), attributes);
  if (visual == NULL) {
    puts("glx_visual=unavailable");
    XCloseDisplay(display);
    return 3;
  }
  Colormap colormap = XCreateColormap(display, RootWindow(display, visual->screen), visual->visual, AllocNone);
  XSetWindowAttributes window_attributes;
  window_attributes.colormap = colormap;
  window_attributes.border_pixel = 0;
  Window drawable = XCreateWindow(display, RootWindow(display, visual->screen), 0, 0, 1, 1, 0,
                                  visual->depth, InputOutput, visual->visual,
                                  CWBorderPixel | CWColormap, &window_attributes);
  GLXContext context = glXCreateContext(display, visual, NULL, True);
  if (context == NULL) {
    puts("glx_context=unavailable");
    XDestroyWindow(display, drawable);
    XFreeColormap(display, colormap);
    XFree(visual);
    XCloseDisplay(display);
    return 4;
  }
  if (!glXMakeCurrent(display, drawable, context)) {
    puts("glx_make_current=unavailable");
    glXDestroyContext(display, context);
    XDestroyWindow(display, drawable);
    XFreeColormap(display, colormap);
    XFree(visual);
    XCloseDisplay(display);
    return 5;
  }

  const GLubyte *vendor = glGetString(GL_VENDOR);
  const GLubyte *renderer = glGetString(GL_RENDERER);
  const GLubyte *version = glGetString(GL_VERSION);
  printf("vendor=%s\n", vendor ? (const char *)vendor : "unavailable");
  printf("renderer=%s\n", renderer ? (const char *)renderer : "unavailable");
  printf("version=%s\n", version ? (const char *)version : "unavailable");
  glXMakeCurrent(display, None, NULL);
  glXDestroyContext(display, context);
  XDestroyWindow(display, drawable);
  XFreeColormap(display, colormap);
  XFree(visual);
  XCloseDisplay(display);
  return version ? 0 : 5;
}

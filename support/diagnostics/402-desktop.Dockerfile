FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
ARG PICKER_BACKEND=zenity
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl dbus-x11 network-manager at-spi2-core thunar fonts-dejavu xfce4-session xfwm4 xfce4-panel xfdesktop4 xvfb xdotool scrot tesseract-ocr python3 libgtk-3-0 libglu1-mesa libappindicator3-1 libayatana-appindicator3-1 libsecret-1-0 xdg-utils xdg-user-dirs zenity fuse && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 probe
RUN apt-get update && apt-get install -y --no-install-recommends imagemagick python3-pyatspi && rm -rf /var/lib/apt/lists/*
RUN if [ "$PICKER_BACKEND" = kdialog ]; then apt-get update && apt-get install -y kdialog && rm -rf /var/lib/apt/lists/*; fi
USER probe
WORKDIR /home/probe
RUN curl -fL --retry 3 https://github.com/localsend/localsend/releases/download/v1.8.0/LocalSend-1.8.0.AppImage -o LocalSend.AppImage && chmod +x LocalSend.AppImage && ./LocalSend.AppImage --appimage-extract
COPY support/diagnostics/402-ui.py /home/probe/ui.py
COPY support/diagnostics/402-session.sh /home/probe/session.sh
COPY support/diagnostics/402-root.sh /home/probe/root.sh
USER root
ENTRYPOINT ["bash", "/home/probe/root.sh"]

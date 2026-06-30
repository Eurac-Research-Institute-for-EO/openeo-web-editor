FROM node:22-alpine AS build

# Path the editor is served under. EURAC hosts it at openeo.eurac.edu/editor,
# so assets and routes are built under /editor/ (vue.config.js reads CLIENT_URL).
ARG CLIENT_URL=/editor/
ENV CLIENT_URL=${CLIENT_URL}

# Backend the editor connects to. config.js is imported into the JS bundle, so
# serverUrl is baked at build time -> the image is environment-specific.
# Override per environment (e.g. https://dev.openeo.eurac.edu/ for dev).
ARG OPENEO_SERVER_URL=https://openeo.eurac.edu/

# Copy source code
COPY . /src/openeo-web-editor
WORKDIR /src/openeo-web-editor

# Point the build at the target backend.
RUN sed -i "s#serverUrl: '[^']*'#serverUrl: '${OPENEO_SERVER_URL}'#" config.js

# Build
RUN npm install
RUN npm run build

# Copy build folder and run with nginx
FROM nginx:1.28.0-alpine
# Serve under /editor/ to match publicPath, with SPA fallback so deep links work.
COPY --from=build /src/openeo-web-editor/dist /usr/share/nginx/html/editor
COPY nginx-editor.conf /etc/nginx/conf.d/default.conf

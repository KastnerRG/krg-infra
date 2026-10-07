# Production image for the PWA: a static Vite build served by unprivileged nginx.
# (Proposed app change — see krg-infra docs/handoff/reference-manager/HANDOFF.md §6.)
#
# VITE_API_URL is baked in at BUILD time (Vite inlines import.meta.env). Production is
# same-origin: the API lives under /api on bib.krg.ucsd.edu.

FROM node:22-alpine AS build
WORKDIR /web
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG VITE_API_URL=/api
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.31.6-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /web/dist /usr/share/nginx/html
EXPOSE 8080

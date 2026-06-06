# Dev-oriented image for the Next.js frontend.
FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install

COPY . .

EXPOSE 3001
CMD ["npm", "run", "dev"]

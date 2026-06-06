# Allow the Next.js frontend to call the API.
# In development we accept any localhost/127.0.0.1 port so the dev port you pick (3001, 3003, …)
# never causes a "Failed to fetch" CORS block. In other environments, FRONTEND_ORIGIN pins it
# (comma-separated list supported).
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    if Rails.env.development?
      origins(%r{\Ahttp://localhost:\d+\z}, %r{\Ahttp://127\.0\.0\.1:\d+\z})
    else
      origins(*ENV.fetch("FRONTEND_ORIGIN", "http://localhost:3001").split(","))
    end

    resource "*",
             headers: :any,
             methods: %i[get post put patch delete options head],
             credentials: false
  end
end

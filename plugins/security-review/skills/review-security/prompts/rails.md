RUBY ON RAILS GUIDANCE:

This diff touches Ruby code. Before flagging a Rails pattern, check the versions that change the answer: the `rails` version in `Gemfile.lock`, the Ruby version in `.ruby-version` or `Gemfile`, and `config.load_defaults` in `config/application.rb`. Before flagging missing authentication or authorization, read the controller's ancestors (for example `ApplicationController` and base API controllers) for inherited `before_action` callbacks.

**Vulnerable patterns (investigate when input is attacker-controlled):**

- **SQL injection:** string interpolation or concatenation in `where`, `find_by_sql`, `select`, `joins`, `group`, `having`, `from`, `lock`, `exists?`, `update_all`, `delete_by`, or `connection.execute`/`select_all`; `Arel.sql(user_input)`; `sanitize_sql` misuse such as interpolating before sanitizing.
- **Command injection:** `system`, backticks, `%x()`, `exec`, `spawn`, `IO.popen`, or `Open3.*` given a single interpolated string; `Kernel#open`, `IO.read`, `IO.readlines`, or `URI.open` given user input, since a leading `|` runs a command.
- **Code execution and reflection:** `constantize`, `safe_constantize`, or `Object.const_get` on params; `send`, `public_send`, `try`, or `method(...).call` with a user-chosen method name; `eval`, `instance_eval`, or `class_eval` with strings; `render inline:` with user content (server-side template injection); `render file:`, `render template:`, or `render partial:` with a user-chosen path; `GlobalID::Locator.locate(params[...])` instead of `locate_signed`.
- **Deserialization:** `Marshal.load` on untrusted data; `YAML.unsafe_load`, `Psych.unsafe_load`, or `YAML.load` on Ruby < 3.1 or with broad `permitted_classes`; `Oj.load` in its default `:object` mode; `JSON.load` on untrusted input (prefer `JSON.parse`); a `:marshal` or `:hybrid` cookie serializer.
- **Mass assignment:** `params.permit!`; `permit` of privileged attributes such as `:role`, `:admin`, `:user_id`, `:account_id`, `:owner_id`, or `:verified`; `to_unsafe_h` fed into `new`, `update`, or `assign_attributes`.
- **Authorization and IDOR:** `Model.find(params[:id])` in a controller with no scoping to `current_user`, no `policy_scope`/`authorize` (Pundit), and no `load_and_authorize_resource` (CanCanCan); `skip_before_action` of authentication, `verify_authenticity_token`, or `verify_authorized` added by this diff; secret-token lookups such as `find_by(reset_token: params[:token])` that do not reject a blank token, since `nil` matches rows whose column is NULL.
- **XSS:** `html_safe`, `raw`, or `<%==` on user content, including interpolated strings like `"<b>#{name}</b>".html_safe`; `link_to` or `href` with a user-controlled URL (`javascript:` scheme); `sanitize` with custom `tags:`/`attributes:` that allow scripts, event handlers, or `style`; user values placed in JavaScript contexts without `j`/`escape_javascript` or `json_escape`.
- **Open redirect:** `redirect_to` with a user-controlled URL and `allow_other_host: true`, or on apps without `raise_on_open_redirects` (Rails < 7.0 defaults).
- **Path traversal and file disclosure:** `send_file`, `File.read`, `File.open`, or `Rails.root.join(..., params[...])` with user input. `Pathname#join` returns the argument itself when given an absolute path. Safe code uses `File.basename`, an allowlist, or a `realpath` prefix check.
- **SSRF:** `Net::HTTP`, `Faraday`, `HTTParty`, `RestClient`, `Down`, or `URI.open` requesting a URL whose host or scheme the user controls, including webhook targets and remote-URL attachments.
- **Crypto and secrets:** `rand`, `Random`, or timestamps used for tokens (use `SecureRandom`); `Digest::MD5`/`SHA1`/`SHA256` for password storage (use `has_secure_password`/bcrypt); `==` comparison of API keys, HMACs, or webhook signatures (use `ActiveSupport::SecurityUtils.secure_compare`, MEDIUM at most); `OpenSSL::SSL::VERIFY_NONE`, `ssl: { verify: false }`, or `verify: false`; `JWT.decode` with verification disabled or an attacker-influenced algorithm; hardcoded `secret_key_base` or credentials.
- **Data exposure:** `render json: @record` or `to_json` that serializes whole models, including password digests, tokens, or PII (use a serializer or `as_json(only: ...)`); logging `params`, `to_unsafe_h`, or request bodies without the keys covered by `config.filter_parameters`; PII such as SSNs, dates of birth, or government identifiers (for example VA ICN, EDIPI, BIRLS ID, file number, or participant ID) in logs, exception messages, Sentry/APM context, or API responses beyond what the client needs.
- **Validation bypass:** `^` and `$` anchors in regexes that guard security decisions (host allowlists, redirect targets, identifiers), which match per line; use `\A` and `\z`.
- **Session and cookies:** auth tokens in plain `cookies[...]` without `httponly: true` and `secure: true` (prefer `cookies.encrypted`); CORS that reflects arbitrary origins with `credentials: true` on cookie-authenticated endpoints; state-changing actions reachable via GET or `match ... via: :all`.

**Framework-mitigated patterns (do not flag unless the mitigation is bypassed):**

- `<%= value %>`, `content_tag`, `link_to` text, `simple_format`, and default `sanitize` are escaped or sanitized.
- Hash conditions (`where(id: params[:id])`), `?` placeholders, named binds, `sanitize_sql_array`, and `find`/`find_by(col: value)` are parameterized.
- `order`, `reorder`, and `pluck` with raw params raise `ActiveRecord::UnknownAttributeReference` on Rails 6.1+, unless the value is wrapped in `Arel.sql`.
- `redirect_to params[:url]` raises on Rails 7.0+ defaults (`raise_on_open_redirects`) unless `allow_other_host: true`.
- `YAML.load` is safe by default on Ruby 3.1+ (Psych 4).
- Passing unpermitted `ActionController::Parameters` to mass assignment raises `ForbiddenAttributesError`.
- `ActionController::Base` enables CSRF protection by default; `ActionController::API` endpoints that authenticate with headers or tokens rather than cookies do not need it.
- `system`, `spawn`, and `Open3` calls with separate arguments do not invoke a shell.
- Secrets read from `Rails.application.credentials` or `ENV` are not hardcoded.
- Brakeman warnings with "Weak" confidence and no attacker-controlled input.

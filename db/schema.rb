# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_19_110439) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_call_logs", force: :cascade do |t|
    t.integer "attempt", default: 1, null: false
    t.integer "cost_micro_usd", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "error_class"
    t.text "error_detail"
    t.integer "input_tokens", default: 0, null: false
    t.integer "latency_ms", default: 0, null: false
    t.string "model", null: false
    t.integer "output_tokens", default: 0, null: false
    t.string "prompt_version", null: false
    t.boolean "success", default: false, null: false
    t.bigint "term_id"
    t.index ["created_at"], name: "index_api_call_logs_on_created_at"
    t.index ["success", "created_at"], name: "index_api_call_logs_on_success_and_created_at"
    t.index ["term_id"], name: "index_api_call_logs_on_term_id"
  end

  create_table "folders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "name"], name: "index_folders_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_folders_on_user_id"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "name"], name: "index_tags_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_tags_on_user_id"
  end

  create_table "term_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "tag_id", null: false
    t.bigint "term_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tag_id"], name: "index_term_tags_on_tag_id"
    t.index ["term_id", "tag_id"], name: "index_term_tags_on_term_id_and_tag_id", unique: true
    t.index ["term_id"], name: "index_term_tags_on_term_id"
  end

  create_table "terms", force: :cascade do |t|
    t.text "context"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.jsonb "examples", default: [], null: false
    t.bigint "folder_id"
    t.datetime "generated_at"
    t.text "meaning"
    t.integer "status", default: 0, null: false
    t.string "suggested_folder_name"
    t.datetime "updated_at", null: false
    t.text "usage_note"
    t.bigint "user_id", null: false
    t.string "word", null: false
    t.index ["folder_id"], name: "index_terms_on_folder_id"
    t.index ["user_id", "created_at"], name: "index_terms_on_user_id_and_created_at", order: { created_at: :desc }
    t.index ["user_id", "status"], name: "index_terms_on_user_id_and_status"
    t.index ["user_id", "word"], name: "index_terms_on_user_id_and_word", unique: true
    t.index ["user_id"], name: "index_terms_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "api_call_logs", "terms", on_delete: :nullify
  add_foreign_key "folders", "users"
  add_foreign_key "tags", "users"
  add_foreign_key "term_tags", "tags"
  add_foreign_key "term_tags", "terms"
  add_foreign_key "terms", "folders", on_delete: :nullify
  add_foreign_key "terms", "users"
end

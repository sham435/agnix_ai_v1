---
globs: "db/migrate/**/*,db/schema.rb,app/models/**/*.rb"
---
# Rails Active Record & MVC Implementation Guide

## Role Definition
You are an expert Ruby on Rails developer specializing in Active Record patterns and MVC architecture. Follow these guidelines strictly when implementing database-related code.

---

## Core Principles

### 1. MVC Pattern & Active Record
- **All database logic MUST reside in models** - never in controllers or views
- Controllers only coordinate between models and views (skinny controllers)
- Use Active Record models as the sole interface for data manipulation
- Follow "fat model, skinny controller" principle

### 2. Schema Naming Conventions (Strict)

| Element | Convention | Example |
|---|---|---|
| Table names | Plural, snake_case | `book_clubs`, `user_profiles` |
| Model class names | Singular, CamelCase | `BookClub`, `UserProfile` |
| Primary key | `id` (default, unless legacy) | `id` |
| Foreign keys | `{singular}_id` | `book_club_id` |
| Timestamps | `created_at`, `updated_at` | auto-managed by Rails |
| Join tables (HABTM) | Lexical order, plural, snake_case | `assemblies_parts` |

### 3. Migrations - DSL First, Never Raw SQL

```ruby
class CreateBooks < ActiveRecord::Migration[8.1]
  def change
    create_table :books, id: :uuid do |t|
      t.string :title, null: false
      t.references :author, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end
    add_index :books, [:author_id, :title], unique: true
  end
end
```

### 4. Validation Rules
- Always validate presence for required fields
- Use built-in helpers before custom validations
- Provide user-friendly error messages
- Validate associations when needed

### 5. Callbacks - Keep Them Simple

```ruby
class Order < ApplicationRecord
  belongs_to :user
  has_many :line_items, dependent: :destroy

  before_validation :set_default_status, on: :create
  after_create :send_confirmation_email

  enum :status, { pending: 0, paid: 1, shipped: 2, cancelled: 3 }

  private

  def set_default_status
    self.status ||= :pending
  end

  def send_confirmation_email
    # Use background job for external calls
    OrderMailer.confirmation(self).deliver_later
  end
end
```

**Callback Rules:**
- Use `before_validation` for normalization
- Use `after_create`/`after_update` for non-critical side effects
- NEVER make external API calls synchronously in callbacks
- Consider service objects for complex callback logic
- Use `around_save` sparingly

### 6. Associations - Choose Correct Type

| Relationship | Correct Association | Foreign Key Location |
|---|---|---|
| Book -> Author | `belongs_to :author` | `books.author_id` |
| Author -> Books | `has_many :books` | `books.author_id` |
| Supplier -> Account | `has_one :account` | `accounts.supplier_id` |
| Physician <-> Patient | `has_many :through` | `appointments` table |
| Simple many-to-many | `has_and_belongs_to_many` | join table only |

**Complete Association Setup:**

```ruby
# app/models/author.rb
class Author < ApplicationRecord
  has_many :books, dependent: :destroy, inverse_of: :author
  has_many :reviews, through: :books
  has_one :profile, dependent: :restrict_with_error

  validates :name, presence: true
end

# app/models/book.rb
class Book < ApplicationRecord
  belongs_to :author, counter_cache: true, touch: true
  has_many :reviews, dependent: :destroy

  validates :title, presence: true
end

# app/models/review.rb
class Review < ApplicationRecord
  belongs_to :book
  belongs_to :user, optional: true

  validates :rating, presence: true, inclusion: 1..5
end
```

**Dependent Options Decision Tree:**
- `:destroy` -> Child needs callbacks run
- `:delete_all` -> Fast deletion, no callbacks needed
- `:nullify` -> Foreign key can be NULL (column must be nullable)
- `:restrict_with_exception` -> Prevent deletion if children exist
- `:restrict_with_error` -> Add error instead of exception

### 7. CRUD Operations - Use Correct Methods

**Create:**

```ruby
# Standard - validates before save
book = Book.new(title: "The Hobbit")
book.save  # returns false on failure

book = Book.create(title: "The Hobbit")  # returns object regardless

# Strict - raises exception
book = Book.create!(title: "The Hobbit")

# Bulk insert - NO callbacks/validations (use sparingly)
Book.insert_all([{ title: "Book 1" }, { title: "Book 2" }])
```

**Read - Optimize Queries:**

```ruby
# Single record - raises if not found
book = Book.find(42)

# Single record - returns nil if not found
book = Book.find_by(title: "The Hobbit")

# Collections
recent_books = Book.where(published: true).order(created_at: :desc).limit(10)

# NEVER do this in a loop (N+1 query)
books.each { |b| b.author.name }  # WRONG

# Use includes for eager loading
books = Book.includes(:author).limit(100)
books.each { |b| b.author.name }  # Only 2 queries total
```

**Update:**

```ruby
# Find and update
book = Book.find(42)
book.update(title: "New Title")  # returns false on failure
book.update!(title: "New Title") # raises on failure

# Bulk update - NO callbacks
Book.where(published: false).update_all(status: "draft")
```

**Delete:**

```ruby
# With callbacks
book.destroy

# Without callbacks (SQL DELETE)
book.delete

# Bulk - with callbacks
Book.destroy_by(author_id: 42)

# Bulk - without callbacks
Book.where(author_id: 42).delete_all
```

### 8. Performance Optimization - Non-negotiable

```ruby
# ALWAYS use includes for associations in loops
def index
  @books = Book.includes(:author, reviews: :user).limit(50)
end

# Use pluck for single column
author_names = Author.where(active: true).pluck(:name)

# Use select for specific columns
books = Book.select(:id, :title, :author_id).limit(100)

# Counter cache for counts
class Book < ApplicationRecord
  belongs_to :author, counter_cache: true  # Requires authors.books_count column
end

# Add indexes in migrations
class AddIndexesToBooks < ActiveRecord::Migration[8.1]
  def change
    add_index :books, :author_id
    add_index :books, [:author_id, :published_at]
    add_index :books, :isbn, unique: true
  end
end
```

### 9. Anti-Patterns - NEVER DO THESE

| Bad | Good |
|---|---|
| `Book.where(...)` in controller | Scope in model: `scope :published, -> { where(published: true) }` |
| Raw SQL in migrations | Rails DSL: `add_column`, `add_index`, `change_column` |
| Missing foreign key indexes | Always `t.references :author, foreign_key: true` |
| N+1 queries | `includes(:association)` or `joins` |
| Callbacks that call external APIs | Use background job (Active Job) |
| HABTM with extra attributes | Use `has_many :through` with join model |
| Forgetting `inverse_of` | Always set `inverse_of` for bi-directional |

---

## Output Requirements

When providing code solutions:
- **Models** - Show complete model with validations, callbacks, associations, and scopes
- **Migrations** - Include reversible migration with proper data types and indexes
- **Controllers** - Demonstrate thin controller logic (only params/permit/redirect/render)
- **Queries** - Show optimized Active Record queries (includes, pluck, select)
- **Explain choices** - Briefly note why you chose specific options

### Example Output Format

```ruby
# app/models/book.rb
class Book < ApplicationRecord
  belongs_to :author, counter_cache: true  # Performance: avoids COUNT queries
  has_many :reviews, dependent: :destroy  # Destroy reviews when book is deleted

  validates :title, presence: true, uniqueness: { scope: :author_id }
  validates :price, numericality: { greater_than_or_equal_to: 0 }

  scope :published, -> { where(published: true).order(published_at: :desc) }

  after_create :notify_author

  private

  def notify_author
    # Using background job for email
    AuthorMailer.new_book_notification(author, self).deliver_later
  end
end

# db/migrate/20240101000000_create_books.rb
class CreateBooks < ActiveRecord::Migration[8.1]
  def change
    create_table :books, id: :uuid do |t|
      t.string :title, null: false
      t.decimal :price, precision: 10, scale: 2, default: 0, null: false
      t.boolean :published, default: false
      t.datetime :published_at
      t.references :author, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end

    add_index :books, [:author_id, :title], unique: true
    add_index :books, :published_at
  end
end
```

class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    # Projects.
    create_table :projects, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.text :instructions
      t.string :root_path
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :projects, [:organization_id, :name]
    add_index :projects, :user_id, name: "idx_projects_on_user_id"

    # Project files.
    create_table :project_files, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :content_type
      t.string :file_path
      t.bigint :size, default: 0
      t.text :content
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :project_files, [:project_id, :filename], unique: true

    # Project links.
    create_table :project_links, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :url, null: false
      t.string :title
      t.text :description
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :project_links, :project_id, name: "idx_project_links_on_project_id"
  end
end

class CreatePollsTables < ActiveRecord::Migration[5.2]
  def change
    create_table :polls do |t|
      t.integer :post_id, null: false
      t.string :name, null: false, default: "poll"
      t.datetime :close_at
      t.string :type, null: false, default: "regular"
      t.string :status, null: false, default: "open"
      t.string :visibility, null: false, default: "private"
      t.string :results, null: false, default: "always"
      t.integer :min
      t.integer :max
      t.integer :step
      t.timestamps
    end

    add_foreign_key :polls, :posts
    add_index :polls, [:post_id, :name], unique: true

    create_table :poll_options do |t|
      t.integer :poll_id, null: false
      t.string :digest, null: false
      t.text :html, null: false
      t.timestamps
    end

    add_foreign_key :poll_options, :polls

    add_index :poll_options, [:poll_id, :digest], unique: true

    create_table :poll_votes, id: false do |t|
      t.integer :poll_id, null: false
      t.integer :poll_option_id, null: false
      t.integer :user_id, null: false
      t.timestamps
    end

    add_foreign_key :poll_votes, :polls
    add_foreign_key :poll_votes, :poll_options
    add_foreign_key :poll_votes, :users

    add_index :poll_votes, [:poll_id, :poll_option_id, :user_id], unique: true
  end
end

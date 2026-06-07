module LoginHelper
  def login_as(user, password: "password123")
    visit login_path
    fill_in "email", with: user.email
    fill_in "password", with: password
    click_button "Sign In"
  end
end

RSpec.configure { |c| c.include LoginHelper, type: :system }

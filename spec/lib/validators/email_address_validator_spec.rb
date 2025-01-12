# frozen_string_literal: true

require 'rails_helper'

describe EmailAddressValidator do
  it 'should match valid emails' do
    ['test@discourse.org', 'good_user@discourse.org', 'incoming+%{reply_key}@discourse.org'].each do |email|
      expect(EmailAddressValidator.valid_value?(email)).to eq(true)
    end
  end

  it 'should not match invalid emails' do
    ['testdiscourse.org', 'frank@invalid_host.contoso.com', 'frank@invalid_host.com', 'test@discourse.org; a@discourse.org', 'random', ''].each do |email|
      expect(EmailAddressValidator.valid_value?(email)).to eq(false)
    end
  end
end

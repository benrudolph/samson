# frozen_string_literal: true
require_relative '../../../test_helper'

SingleCov.covered!

describe Samson::Secrets::HashicorpVaultBackend do
  include VaultRequestHelper

  let(:backend) { Samson::Secrets::HashicorpVaultBackend }

  it "keeps segments in sync with storage" do
    Samson::Secrets::HashicorpVaultBackend::KEY_SEGMENTS.must_equal SecretStorage::SECRET_KEYS_PARTS.size
  end

  describe ".read" do
    it "reads" do
      assert_vault_request :get, "production/foo/pod2/bar", body: {data: { vault: "SECRET"}}.to_json do
        backend.read('production/foo/pod2/bar').must_equal(
          auth: nil,
          lease_duration: nil,
          lease_id: nil,
          renewable: nil,
          warnings: nil,
          wrap_info: nil,
          value: "SECRET"
        )
      end
    end

    it "returns nil when it fails to read" do
      assert_vault_request :get, "production/foo/pod2/bar", status: 404 do
        backend.read('production/foo/pod2/bar').must_be_nil
      end
    end

    it "returns nil when trying to read nil" do
      backend.read(nil).must_be_nil
    end

    it "raises when trying to read an invalid path so it behaves like a database backend" do
      assert_raises ActiveRecord::RecordNotFound do
        backend.read("wut")
      end
    end
  end

  describe ".read_multi" do
    it "returns values as hash" do
      assert_vault_request :get, "production/foo/pod2/bar", body: {data: { vault: "SECRET"}}.to_json do
        backend.read_multi(['production/foo/pod2/bar']).must_equal(
          'production/foo/pod2/bar' => {
            auth: nil,
            lease_duration: nil,
            lease_id: nil,
            renewable: nil,
            warnings: nil,
            wrap_info: nil,
            value: "SECRET"
          }
        )
      end
    end

    it "leaves out unfound values" do
      assert_vault_request :get, "production/foo/pod2/bar", status: 404 do
        backend.read_multi(['production/foo/pod2/bar']).must_equal({})
      end
    end

    it "leaves out vaules from deploy groups that have no vault server so KeyResolver works" do
      backend.read_multi(['production/foo/pod100/bar']).must_equal({})
    end

    it "leaves out vaules from unknown deploy groups" do
      backend.read_multi(['production/foo/pod1nope/bar']).must_equal({})
    end
  end

  describe ".delete" do
    it "deletes" do
      assert_vault_request :delete, "production/foo/pod2/bar" do
        assert backend.delete('production/foo/pod2/bar')
      end
    end
  end

  describe ".write" do
    let(:data) { {vault: "whatever", visible: false, comment: "secret!", creator_id: 1, updater_id: 1} }
    let(:old_data) { data.merge(vault: "old") }

    it "creates" do
      assert_vault_request :get, "production/foo/pod2/bar", status: 404 do
        assert_vault_request :put, "production/foo/pod2/bar", with: {body: data.to_json} do
          assert backend.write(
            'production/foo/pod2/bar', value: 'whatever', visible: false, user_id: 1, comment: 'secret!'
          )
        end
      end
    end

    it "updates without changing the creator" do
      data[:creator_id] = 2 # testing that creator does not get changed to user_id
      data[:visible] = true # testing that we can set true too
      assert_vault_request :get, "production/foo/pod2/bar", body: {data: old_data}.to_json do
        assert_vault_request :put, "production/foo/pod2/bar", with: {body: data.to_json} do
          assert backend.write(
            'production/foo/pod2/bar', value: 'whatever', visible: true, user_id: 1, comment: 'secret!'
          )
        end
      end
    end

    it "reverts when it could not update" do
      assert_raises Vault::HTTPServerError do
        assert_vault_request :get, "production/foo/pod2/bar", body: {data: old_data}.to_json do
          assert_vault_request :put, "production/foo/pod2/bar", with: {body: data.to_json}, status: 500 do
            assert_vault_request :put, "production/foo/pod2/bar", with: {body: old_data.to_json} do
              assert backend.write(
                'production/foo/pod2/bar', value: 'whatever', visible: false, user_id: 1, comment: 'secret!'
              )
            end
          end
        end
      end
    end

    it "reverts when it could not create" do
      assert_raises Vault::HTTPServerError do
        assert_vault_request :get, "production/foo/pod2/bar", status: 404 do
          assert_vault_request :put, "production/foo/pod2/bar", with: {body: data.to_json}, status: 500 do
            assert_vault_request :delete, "production/foo/pod2/bar" do
              assert backend.write(
                'production/foo/pod2/bar', value: 'whatever', visible: false, user_id: 1, comment: 'secret!'
              )
            end
          end
        end
      end
    end
  end

  describe ".keys" do
    it "lists all keys with recursion" do
      first_keys = {data: {keys: ["production/project/group/this/", "production/project/group/that/"]}}
      sub_key = {data: {keys: ["key"]}}

      assert_vault_request :get, "?list=true", body: first_keys.to_json do
        assert_vault_request :get, "production/project/group/this/?list=true", body: sub_key.to_json do
          assert_vault_request :get, "production/project/group/that/?list=true", body: sub_key.to_json do
            backend.keys.must_equal(
              [
                "production/project/group/this/key",
                "production/project/group/that/key"
              ]
            )
          end
        end
      end
    end
  end

  describe ".filter_keys_by_value" do
    let(:key) { "production/foo/pod2/bar" }

    it "ignore non-matching" do
      assert_vault_request :get, key, body: {data: { vault: "SECRET"}}.to_json do
        backend.filter_keys_by_value([key], 'NOPE').must_equal []
      end
    end

    it "finds matching" do
      missing = "production/foo/pod2/nope"
      assert_vault_request :get, key, body: {data: { vault: "SECRET"}}.to_json do
        assert_vault_request :get, missing, status: 404 do
          backend.filter_keys_by_value([key, missing], "SECRET").must_equal [key]
        end
      end
    end
  end

  describe "raises BackendError when a vault instance is down/unreachable" do
    let(:client) { Samson::Secrets::VaultClient.client }

    it ".keys" do
      client.expects(:list_recursive).
        raises(Vault::HTTPConnectionError.new("address", RuntimeError.new('no keys for you')))
      e = assert_raises Samson::Secrets::BackendError do
        backend.keys
      end
      e.message.must_include('no keys for you')
    end

    it ".read" do
      client.expects(:read).raises(Vault::HTTPConnectionError.new("address", RuntimeError.new('no read for you')))
      e = assert_raises Samson::Secrets::BackendError do
        backend.read('production/foo/group/isbar/foo')
      end
      e.message.must_include('no read for you')
    end

    it ".write" do
      client.expects(:read).returns(nil)
      client.expects(:write).raises(Vault::HTTPConnectionError.new("address", RuntimeError.new('no write for you')))
      e = assert_raises Samson::Secrets::BackendError do
        backend.write(
          'production/foo/group/isbar/foo', value: 'whatever', visible: false, user_id: 1, comment: 'secret!'
        )
      end
      e.message.must_include('no write for you')
    end
  end

  describe ".convert_path" do
    it "fails with invalid direction" do
      assert_raises ArgumentError do
        backend.send(:convert_path!, 'x', :ooops)
      end
    end
  end

  describe ".deploy_groups" do
    it "does not include ones that could not be selected" do
      backend.deploy_groups.must_equal [deploy_groups(:pod2)]
    end
  end
end

# frozen_string_literal: true

require "securerandom"
require "nokogiri"
require "openssl"
require_relative "./encryptor"

module FakeIdp
  class SamlResponse
    DSIG = "http://www.w3.org/2000/09/xmldsig#"
    SAML_VERSION = "2.0"
    ASSERTION_NAMESPACE = "urn:oasis:names:tc:SAML:2.0:assertion"
    ENTITY_FORMAT = "urn:oasis:names:SAML:2.0:nameid-format:entity"
    BEARER_FORMAT = "urn:oasis:names:tc:SAML:2.0:cm:bearer"
    ENVELOPE_SCHEMA = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
    STATUS_CODE_VALUE = "urn:oasis:names:tc:SAML:2.0:status:Success"
    FEDERATION_SOURCE = "urn:federation:authentication:windows"
    EMAIL_ADDRESS_FORMAT = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

    # For the time being we're only supporting a single canonical schema since
    # supporting multiple is inconsequential for our immediate need.
    CANONICAL_VALUE = 1
    CANONICAL_SCHEMA = "http://www.w3.org/2001/10/xml-exc-c14n#"

    def initialize(
      name_id:,
      issuer_uri:,
      saml_acs_url:,
      saml_request_id:,
      user_attributes:,
      algorithm_name:,
      certificate:,
      secret_key:,
      encryption_enabled: false
    )
      @name_id = name_id
      @issuer_uri = issuer_uri
      @saml_acs_url = saml_acs_url
      @saml_request_id = saml_request_id
      @user_attributes = user_attributes
      @algorithm_name = algorithm_name
      @certificate = certificate
      @secret_key = secret_key
      @encryption_enabled = encryption_enabled
      @builder = Nokogiri::XML::Builder.new
      @timestamp = Time.now
    end

    def build
      @builder[:samlp].Response(root_namespace_attributes) do |response|
        build_issuer_segment(response)
        build_status_segment(response)
        build_assertion_segment(response)
      end

      document_with_digest = replace_digest_value(@builder.to_xml)
      document = replace_signature_value(document_with_digest)
      encrypt_assertion!(document)
    end

    private

    def encrypt_assertion!(document)
      return document unless @encryption_enabled

      document_copy = document.dup
      working_document = Nokogiri::XML(document)
      assertion = working_document.at_xpath("//saml:Assertion", "saml" => ASSERTION_NAMESPACE)
      encrypted_assertion_xml = FakeIdp::Encryptor.new(
        assertion.to_xml,
        @certificate,
      ).encrypt

      document_copy = Nokogiri::XML(document_copy)
      target_assertion_node = document_copy.at_xpath(
        "//saml:Assertion",
        "saml" => ASSERTION_NAMESPACE,
      )
      # Replace Assertion node with encrypted assertion
      target_assertion_node.replace(encrypted_assertion_xml)
      document_copy.to_xml
    end

    def replace_digest_value(document)
      document_copy = document.dup
      working_document = Nokogiri::XML(document)

      # The signature element needs to be removed from the assertion before creating a digest
      signature_element = working_document.at_xpath("//ds:Signature", "ds" => DSIG)
      signature_element.remove

      assertion_without_signature = working_document.
        at_xpath("//*[@ID=$id]", nil, "id" => assertion_reference_response_id)
      canon_hashed_element = assertion_without_signature.canonicalize(CANONICAL_VALUE)

      digest_value = Base64.encode64(algorithm.digest(canon_hashed_element)).strip

      # Replace digest node with the generated value
      document_copy = Nokogiri::XML(document_copy)
      target_digest_node = document_copy.at_xpath("//ds:DigestValue", "ds" => DSIG)
      target_digest_node.content = digest_value
      document_copy
    end

    def replace_signature_value(document)
      document_copy = document.dup
      signature_element = document.at_xpath("//ds:Signature", "ds" => DSIG)

      # The SignatureValue is a signed copy of the SignedInfo element
      signed_info_element = signature_element.at_xpath("./ds:SignedInfo", "ds" => DSIG)
      canon_string = signed_info_element.canonicalize(CANONICAL_VALUE)

      signature_value = sign(canon_string)

      target_signature_node = document_copy.at_xpath("//ds:SignatureValue", "ds" => DSIG)
      target_signature_node.content = signature_value
      document_copy.to_xml
    end

    def build_issuer_segment(parent_attribute)
      parent_attribute[:saml].Issuer("xmlns:saml" => ASSERTION_NAMESPACE) do |issuer|
        issuer << @issuer_uri
      end
    end

    def build_status_segment(parent_attribute)
      parent_attribute[:samlp].Status do |status|
        status[:samlp].StatusCode("Value" => STATUS_CODE_VALUE)
      end
    end

    def build_assertion_segment(parent_attribute)
      parent_attribute[:saml].Assertion(assertion_namespace_attributes) do |assertion|
        assertion[:saml].Issuer("Format" => ENTITY_FORMAT) do |issuer|
          issuer << @issuer_uri
        end

        build_assertion_signature(assertion)

        assertion[:saml].Subject do |subject|
          subject[:saml].NameID("Format" => EMAIL_ADDRESS_FORMAT) do |name_id|
            name_id << @name_id
          end

          subject[:saml].SubjectConfirmation("Method" => BEARER_FORMAT) do |subject_confirmation|
            subject_confirmation[:saml].SubjectConfirmationData(subject_confirmation_data) { "" }
          end
        end

        assertion[:saml].Conditions(saml_conditions) do |conditions|
          conditions[:saml].AudienceRestriction do |restriction|
            restriction[:saml].Audience { |audience| audience << @issuer_uri }
          end
        end

        assertion[:saml].AttributeStatement do |attribute_statement|
          @user_attributes.map do |name, value|
            attribute_statement[:saml].Attribute("Name" => name) do |attribute|
              attribute[:saml].AttributeValue { |attribute_value| attribute_value << value }
            end
          end
        end

        assertion[:saml].AuthnStatement(authn_statement) do |statement|
          statement[:saml].AuthnContext do |authn_context|
            authn_context[:saml].AuthnContextClassRef do |context_class_ref|
              context_class_ref << FEDERATION_SOURCE
            end
          end
        end
      end
    end

    def build_assertion_signature(parent_attribute)
      parent_attribute[:ds].Signature("xmlns:ds" => DSIG) do |signature|
        signature[:ds].SignedInfo("xmlns:ds" => DSIG) do |signed_info|
          signed_info[:ds].CanonicalizationMethod("Algorithm" => CANONICAL_SCHEMA)
          signed_info[:ds].SignatureMethod("Algorithm" => "#{DSIG}#{@algorithm_name}")

          signed_info[:ds].Reference("URI" => reference_uri) do |reference|
            reference[:ds].Transforms do |transform|
              transform[:ds].Transform("Algorithm" => ENVELOPE_SCHEMA)
              transform[:ds].Transform("Algorithm" => CANONICAL_SCHEMA)
            end

            reference[:ds].DigestMethod("Algorithm" => "#{DSIG}#{@algorithm_name}")

            # The digest_value is set and derived from creating a digest of the Assertion element
            # without the signature element after the document is generated
            reference[:ds].DigestValue("xmlns:ds" => DSIG) { |d| d << "" }
          end
        end

        # The signature_value is set and derived from signing the SignedInfo element after the
        # document is generated
        signature[:ds].SignatureValue { |signature_value| signature_value << "" }

        signature.KeyInfo("xmlns:ds" => DSIG) do |key_info|
          key_info[:ds].X509Data do |x509_data|
            x509_data[:ds].X509Certificate do |x509_certificate|
              x509_certificate << Base64.encode64(@certificate)
            end
          end
        end
      end
    end

    def algorithm
      raise "Algorithm name must be a Symbol" unless @algorithm_name.is_a?(Symbol)

      case @algorithm_name
      when :sha256 then OpenSSL::Digest::SHA256
      when :sha384 then OpenSSL::Digest::SHA384
      when :sha512 then OpenSSL::Digest::SHA512
      else
        OpenSSL::Digest::SHA1
      end
    end

    def sign(data)
      key = OpenSSL::PKey::RSA.new(@secret_key)
      Base64.encode64(key.sign(algorithm.new, data)).gsub(/\n/, "")
    end

    def reference_response_id
      @_reference_response_id ||= "_#{SecureRandom.uuid}"
    end

    def assertion_reference_response_id
      @assertion_reference_response_id ||= "_#{SecureRandom.uuid}"
    end

    def reference_uri
      "_#{assertion_reference_response_id}"
    end

    def root_namespace_attributes
      {
        "xmlns:samlp" => "urn:oasis:names:tc:SAML:2.0:protocol",
        "Consent" => "urn:oasis:names:tc:SAML:2.0:consent:unspecified",
        "Destination" => @saml_acs_url,
        "ID" => reference_response_id,
        "InResponseTo" => @saml_request_id,
        "IssueInstant" => @timestamp.strftime("%Y-%m-%dT%H:%M:%S"),
        "Version" => SAML_VERSION,
      }
    end

    def assertion_namespace_attributes
      {
        "xmlns:saml" => ASSERTION_NAMESPACE,
        "ID" => assertion_reference_response_id,
        "IssueInstant" => @timestamp.strftime("%Y-%m-%dT%H:%M:%S"),
        "Version" => SAML_VERSION,
      }
    end

    def subject_confirmation_data
      {
        "InResponseTo" => @saml_request_id,
        "NotOnOrAfter" => (@timestamp + 3 * 60).strftime("%Y-%m-%dT%H:%M:%S"),
        "Recipient" => @saml_acs_url,
      }
    end

    def saml_conditions
      {
        "NotBefore" => (@timestamp - 5).strftime("%Y-%m-%dT%H:%M:%S"),
        "NotOnOrAfter" => (@timestamp + 60 * 60).strftime("%Y-%m-%dT%H:%M:%S"),
      }
    end

    def authn_statement
      {
        "AuthnInstant" => @timestamp.strftime("%Y-%m-%dT%H:%M:%S"),
        "SessionIndex" => reference_response_id,
      }
    end
  end
end

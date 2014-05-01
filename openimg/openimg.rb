# -*- coding: utf-8 -*-

Plugin.create :openimg do
  @addsupport_added = false
  @supports = []

  # クラスメソッドが追加されたとき
  def singleton_method_added(name)

    # addsupport()が追加された
    if !@addsupport_added && name == :addsupport
      @addsupport_added = true
      
      class << self
        # addsupport()を置き換える
        alias_method :addsupport_org, :addsupport  

        def addsupport(cond, element_rule = {}, &block)
          # 画像URL取得処理を横取りする
          @supports << {:cond => cond, :element_rule => element_rule, :block => block}
          addsupport_org(cond, element_rule, &block)
        end
      end
    end
  end

  # リンクのURIから画像のURIを得る
  def get_image_url(url)
    result = nil

    if url =~ /.*\.(?:jpg|png|gif|)$/
      return url
    end

    real_url = MessageConverters.expand_url_one(url)

    proc = nil

    @supports.each { |support|
      if real_url =~ support[:cond]
        if support[:block] 
          cancel = false
          result = imgurlresolver(real_url, support[:element_rule]){ |image_url| support[:block].call(image_url, cancel) } 
        else
          result = imgurlresolver(real_url, support[:element_rule])
        end

        break
      end
    }

    result
  end

  # 本物のopenimgをロードする
  load File.join(File.dirname($0), "core", "plugin", "openimg", "openimg.rb")

end



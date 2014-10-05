# -*- coding: utf-8 -*-
miquire :mui, 'sub_parts_helper'

require 'gtk2'
require 'cairo'


# 画像ローダー
class ImageLoadHelper

  # 0.2,0.3両対応の優先度設定
  def self.ui_passive
    if Delayer.const_defined?(:UI_PASSIVE)
      Delayer::UI_PASSIVE
    else
      :ui_passive
    end
  end

  # メッセージに含まれるURLとエンティティを抽出する
  def self.extract_urls_by_message(message)
    target = []

    if message[:entities]
      target = message[:entities][:urls].map { |m| { :url => m[:expanded_url], :entity => m } }

      if message[:entities][:media]
        target += message[:entities][:media].map { |m| { :url => m[:media_url], :entity => m } }
      end
    end

    target
  end


  # 画像URLを取得
  def self.get_image_urls(message)
    target = extract_urls_by_message(message)

    result = target.map { |entity|
      base_url = entity[:url]
      image_url = Plugin[:openimg].get_image_url(base_url)

      if image_url
        {:page_url => base_url, :image_url => image_url, :entity => entity[:entity] }
      else
        nil
      end
    }.compact.sort { |a| a[:entity][:indices][0] } 

    result
  end


  # 画像をダウンロードする
  def self.load_start(msg)
    urls = get_image_urls(msg[:message])

    if urls.empty?
      return
    end

    Delayer.new(ui_passive) {
      msg[:on_image_information].call(urls)
    }

    urls.each_with_index { |url, i|
      main_icon = nil
      parts_height = UserConfig[:subparts_image_height]

      # 画像のロード
      image = Gdk::WebImageLoader.get_raw_data(url[:image_url]) { |data, exception|
        # 即ロード出来なかった => ロード完了

        if !exception && data
          begin
            loader = Gdk::PixbufLoader.new
            loader.write data
            loader.close
 
            main_icon = loader.pixbuf
          rescue => e
            puts e
            puts e.backtrace
            main_icon = Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt
          end
        else
          main_icon = Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt
        end

        if main_icon
          # コールバックを呼び出す
          Delayer.new(ui_passive) {
            msg[:on_image_loaded].call(i, url, main_icon)
          }
        end
      }


      main_icon = case image
        # ロード失敗
        when nil
          Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt

        # 即ロード出来なかった -> ロード中を表示して後はコールバックに任せる
        when :wait
          Gdk::WebImageLoader.loading_pixbuf(parts_height, parts_height).melt

        # 即ロード成功
        else
          loader = Gdk::PixbufLoader.new
          loader.write image
          loader.close

          loader.pixbuf
      end

      # コールバックを呼び出す
      Delayer.new(ui_passive) {
        msg[:on_image_loaded].call(i, url, main_icon)
      }
    }
  end


  # 画像ロードを依頼する
  @@queue = nil

  def self.add(message, proc_image_information, proc_image_loaded)
    if !@@queue
      @@queue = Queue.new

      Thread.start {
        while true
          msg = @@queue.pop
          load_start(msg)
        end
      }
    end

    @@queue.push({:message => message, :on_image_information => proc_image_information, :on_image_loaded => proc_image_loaded})
  end
end


# ここからプラグイン本体
Plugin.create :sub_parts_image do
  UserConfig[:subparts_image_height] ||= 200
  UserConfig[:subparts_image_tp] ||= 100
  UserConfig[:subparts_image_round] ||= 10


  settings "インライン画像表示" do
    adjustment("高さ(px)", :subparts_image_height, 10, 999)
    adjustment("濃さ(%)", :subparts_image_tp, 0, 100)
    adjustment("角を丸くする", :subparts_image_round, 0, 200)
  end


  on_boot do |service|
    # YouTube thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/youtu.be\//, nil) { |url, cancel|
      if url =~ /^http:\/\/youtu.be\/([^\?\/\#]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/^https?:\/\/www\.youtube\.com\/watch\?v=/, nil) { |url, cancel|
      if url =~ /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    # Nikoniko Video thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/nico.ms\/sm/, nil) { |url, cancel|
      if url =~ /^http:\/\/nico.ms\/sm([0-9]+)/
        "http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/nicovideo\.jp\/watch\//, nil) { |url, cancel|
      if url =~ /nicovideo\.jp\/watch\/sm([0-9]+)/
        "http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}"
      else
        nil
      end
    }
  end


  # サブパーツ
  class Gdk::SubPartsImage < Gdk::SubParts
    regist

    def on_image_loaded(pos, url, pixbuf)
      # イメージ取得完了

      if !helper.destroyed?
        # 再描画イベント
        sid = helper.ssc(:expose_event, helper) {
          # サブパーツ描画
          helper.on_modify
          helper.signal_handler_disconnect(sid)
          false 
        }
      end

      # 初回表示の場合、TLの高さを変更する
      first_disp = @main_icons.empty?
      @main_icons[pos] = pixbuf

      if first_disp
        helper.reset_height
      end

      # サブパーツ描画
      helper.on_modify
    end


    def on_image_information(urls)
      @num = urls.length

      if !helper.destroyed?
        # クリックイベント
        @ignore_event = false

        if @click_sid
           helper.signal_handler_disconnect(@click_sid)
           @click_sid = nil
        end

        # クリック位置の特定
        offset = helper.mainpart_height

        helper.subparts.each { |part|
          if part == self
            break
          end

          offset += part.height
        }

        @click_sid = helper.ssc(:click) { |this, e, x, y|
          @num.times { |i|
            # イメージをクリックした
            if (offset + (i * UserConfig[:subparts_image_height])) <= y && (offset + ((i + 1) * UserConfig[:subparts_image_height])) >= y
              case e.button
              when 1
                Gtk::openurl(urls[i][:page_url])
              end
            end
          }
        }
      end
    end


    def initialize(*args)
      super
      @main_icons = []

      if message
        # イメージ読み込みスレッドを起こす
        ImageLoadHelper.add(message, method(:on_image_information), method(:on_image_loaded))
      end
    end


    # サブパーツを描画
    def render(context)
      Array(@main_icons).each_with_index { |icon, i|
        if icon
          parts_height = UserConfig[:subparts_image_height]

          context.save {
            width_ratio = context.clip_extents[2] / icon.width 
            height_ratio = parts_height.to_f / icon.height
            scale_xy = [height_ratio, width_ratio].min
 
            context.translate((context.clip_extents[2] - icon.width * scale_xy) / 2, parts_height * i)
            context.scale(scale_xy, scale_xy)
            context.set_source_pixbuf(icon)

            context.clip {
              round = UserConfig[:subparts_image_round] / scale_xy
              context.rounded_rectangle(0, 0, icon.width, icon.height, round)
            }

            context.paint(UserConfig[:subparts_image_tp] / 100.0)
          }
        end
      }
    end


    def height
      if !@main_icons.empty?
        @num * UserConfig[:subparts_image_height]
      else
        0
      end
    end


    private

    def message
      helper.message
    end
  end
end

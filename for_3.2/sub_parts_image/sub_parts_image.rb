# -*- coding: utf-8 -*-
miquire :mui, 'sub_parts_helper'

require 'gtk2'
require 'cairo'

Plugin.create :sub_parts_image do
  UserConfig[:subparts_image_height] ||= 200
  UserConfig[:subparts_image_tp] ||= 100
  UserConfig[:subparts_image_round] ||= 10


  settings "インライン画像表示" do
    adjustment("高さ(px)", :subparts_image_height, 10, 999)
    adjustment("濃さ(%)", :subparts_image_tp, 0, 100)
    adjustment("角を丸くする", :subparts_image_round, 0, 200)
  end

  defimageopener('youtube thumbnail (shrinked)', /^http:\/\/youtu.be\/([^\?\/\#]+)/) do |url|
    /^http:\/\/youtu.be\/([^\?\/\#]+)/.match(url)
    open("http://img.youtube.com/vi/#{$1}/0.jpg")
  end

  defimageopener('youtube thumbnail', /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/) do |url|
    /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/.match(url)
    open("http://img.youtube.com/vi/#{$1}/0.jpg")
  end

  defimageopener('niconico video thumbnail(shrinked)', /^http:\/\/nico.ms\/sm([0-9]+)/) do |url|
    /^http:\/\/nico.ms\/sm([0-9]+)/.match(url)
    open("http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}")
  end


  defimageopener('niconico video thumbnail', /nicovideo\.jp\/watch\/sm([0-9]+)/) do |url|
    /nicovideo\.jp\/watch\/sm([0-9]+)/.match(url)
    open("http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}")
  end

  # サブパーツ
  class Gdk::SubPartsImage < Gdk::SubParts
    regist

    def on_image_loaded(pos, pixbuf)
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

        @click_sid = helper.ssc(:click) { |this, e, x, y|
          # クリック位置の特定
          offset = helper.mainpart_height

          helper.subparts.each { |part|
            if part == self
              break
            end

            offset += part.height
          }

          @num.times { |i|
            # イメージをクリックした
            if (offset + (i * UserConfig[:subparts_image_height])) <= y && (offset + ((i + 1) * UserConfig[:subparts_image_height])) >= y
              case e.button
              when 1
                Plugin.call(:openimg_open, urls[i])
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
        #ImageLoadHelper.add(message, method(:on_image_information), method(:on_image_loaded))
        Thread.new(message) { |message|
          streams = message.entity
                    .select{ |entity| %i<urls media>.include? entity[:slug] }
                    .map{ |entity| Plugin.filtering(:openimg_raw_image_from_display_url, entity[:url], nil) }
                    .select{ |pair| pair.last }
          Delayer.new{ on_image_information streams.map(&:first) }
          streams.each.with_index do |pair, index|
            _, stream = *pair
            Thread.new { Gdk::PixbufLoader.open{ |loader| loader.write(stream.read) }.pixbuf }
              .next{ |pixbuf| on_image_loaded(index, pixbuf) }
              .trap{ |exception| error exception }
          end
        }.trap{ |exception| error exception }
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

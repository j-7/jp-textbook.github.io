#!/usr/bin/env ruby

require "csv"
require "roo"
require "nkf"
require "logger"
require_relative "util.rb"

if $0 == __FILE__
  include Textbook
if ARGV.size < 1
  puts "USAGE: #$0 data.csv"
  exit
end

logger = Logger.new(STDERR, level: :info)

puts <<EOF
@prefix schema:    <http://schema.org/>.
@prefix bf:        <http://id.loc.gov/ontologies/bibframe/>.
@prefix nier:      <http://dl.nier.go.jp/library/vocab/>.
@prefix textbook:  <https://w3id.org/jp-textbook/>.
EOF

done = {}
c = load_turtle("curriculum.ttl")
fix_curriculums = c.keys.select do |k| # cf. #59
  if c[k]["https://w3id.org/jp-textbook/school"].first == "http://ja.dbpedia.org/resource/高等学校"
    case c[k]["http://schema.org/startDate"].first
    when "1994-04-01", "2003-04-01", "2013-04-01"
      true
    else
      false
    end
  end
end

tempfile = "temp-#{$$}.txt"
io = File.open(tempfile, "w")
xlsx = Roo::Excelx.new(ARGV[0])
xlsx.each_row_streaming(pad_cells: true) do |row|
  io.puts row.join("\t")
end
xlsx.close
io.close

CSV.foreach(tempfile, col_sep: "\t", headers: true) do |row|
  uri = [BASE_URI, row["学校種別"], row["検定年(西暦)"], row["教科書記号"], row["教科書番号"]].join("/")
  #curriculum = [BASE_URI, "curriculum", row["学校種別"], row["検定年(西暦)"]].join("/") #TODO
  curriculum = row["学習指導URI"]
  next if not curriculum =~ %r|https://w3id.org/jp-textbook/curriculum/.+|
  subject_area = row["教科"]
  subject_area = row["検索用教科"] if subject_area.nil? or subject_area.empty?
  subject = row["種目"]
  subject = row["検索用種目"] if subject.nil? or subject.empty?
  subject = NKF.nkf("-wZ1", subject).gsub(/\s+/, "")
  subject = subject.gsub(/1/, "I").gsub(/2/, "II").gsub(/3/, "III")
  school = row["学校種別"]
  grade = row["学年"].to_s.gsub(/　/, "")
  if not grade.empty? and grade.strip.empty?
    logger.warn "Space included at grade data: #{grade.inspect}: #{uri}"
    grade = nil
  end
  pages = row["ページ数・大きさ"].to_s.strip
  unless pages.empty?
    pages = pages.split(/\s*;\s*/)
    if /\A\d+\Z/ =~ pages[0]
      extent, dimensions = pages
    else
      dimensions, extent = pages
    end
  end
  data = {
    "schema:name" => row["書名"],
    "schema:editor" => row["編著者"],
    "schema:publisher" => row["発行者"],
    "schema:bookEdition" => row["版"],
    "textbook:item" => {
      "nier:callNumber" => row["請求記号"],
      "nier:recordID" => row["書誌ID"],
    },
    "textbook:catalogue" => "#{BASE_URI}/catalogue/#{row["学校種別"]}/#{row["★教科書目録掲載年度"]}",
    "textbook:school" => "http://ja.dbpedia.org/resource/#{school}",
    "textbook:subjectArea" => "#{curriculum}/#{subject_area}",
    "textbook:subject" => "#{curriculum}/#{subject_area}/#{subject}",
    "textbook:grade" => grade,
    "textbook:curriculum" => "#{curriculum}",
    "textbook:authorizedYear" => row["検定年(西暦)"],
    "textbook:usageYear" => row["使用年度(西暦)"],
    "textbook:textbookSymbol" => row["教科書記号"],
    "textbook:textbookNumber" => row["教科書番号"],
    "bf:extent" => extent,
    "bf:dimensions" => dimensions,
  }
  if subject == subject_area and fix_curriculums.include?( curriculum )
    if subject_area != "保健体育"
      data.delete("textbook:subject")
      logger.debug "REMOVE subject: "+ [uri, subject, subject_area].inspect
    end
  end
  %w[ textbook:usageYear textbook:authorizedYear ].each do |year|
    if data[year].split(/\D+/).find{|i| i.to_i > Date.today.year }
      logger.warn "Year (#{year}=#{ data["textbook:usageYear"]}) is greater than today. cf. <#{uri}>"
    end
  end
  if done[uri]
    done_items = done[uri]["textbook:item"]
    record_ids = done_items.respond_to?(:key?) ? done_items["nier:recordID"] : done_items.map{|e| e["nier:recordID"] }.join(",")
    logger.warn "#{uri} duplicates! [#{record_ids}/#{data["textbook:item"]["nier:recordID"]}] (#{done[uri]["textbook:usageYear"]} vs #{data["textbook:usageYear"]})"
    if done[uri]["textbook:usageYear"] > data["textbook:usageYear"]
      tmp = done[uri].dup
      done[uri] = data.dup
      data = tmp
    end
    prev_years = done[uri]["textbook:usageYear"].split(/\D+/).map{|i| i.to_i }
    next_years = data["textbook:usageYear"].split(/\D+/).map{|i| i.to_i }
    done[uri]["textbook:usageYear"] << ", #{data["textbook:usageYear"]}"
    note = "#{next_years[0]}年度より"
    %w[ schema:publisher schema:name schema:editor schema:bookEdition
        textbook:school textbook:subjectArea textbook:subject textbook:grade textbook:curriculum
        textbook:authorizedYear textbook:textbookSymbol textbook:textbookNumber
    ].each do |property|
      if not compare_ignorespaces(done[uri][property], data[property])
        logger.warn "  #{property}: #{done[uri][property]} vs #{data[property]}" 
        note << %Q[#{PROPERTY_LABEL[property]}を「#{data[property]}」に変更。]
      end
    end
    %w[ textbook:catalogue textbook:item ].each do |property|
      done[uri][property] = [ done[uri][property] ]
      done[uri][property] << data[property]
    end
    done[uri]["textbook:note"] = note
  else
    done[uri] = data
  end
end

done.sort_by{|k,v| k }.each do |uri, data|
  str = [ "<#{uri}> a schema:Book" ]
  %w[ schema:name schema:editor schema:publisher schema:bookEdition textbook:item
      textbook:catalogue textbook:school textbook:subjectArea textbook:subject textbook:grade textbook:curriculum
      textbook:authorizedYear textbook:usageYear
      bf:extent bf:dimensions
      textbook:textbookSymbol textbook:textbookNumber 
      textbook:note
  ].each do |property|
    if data[property] and not data[property].empty?
      str << format_property(property, data[property])
    end
  end
  print str.join(";\n")
  puts "."
end

end

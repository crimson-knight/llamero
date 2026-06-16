# Amber controllers

A controller groups the actions that respond to a resource's routes. Controllers
inherit from `ApplicationController` and define one public method per action.

## A minimal controller

The smallest useful controller renders an index action:

```crystal
class ArticlesController < ApplicationController
  def index
    articles = Article.all
    render("articles/index.slang")
  end
end
```

## RESTful actions

A full resource controller implements the seven REST actions. Each action reads
`params`, touches the model, and renders or redirects:

```crystal
class ArticlesController < ApplicationController
  def index
    @articles = Article.all
    render("articles/index.slang")
  end

  def show
    @article = Article.find!(params[:id])
    render("articles/show.slang")
  end

  def new
    @article = Article.new
    render("articles/new.slang")
  end

  def create
    @article = Article.new(article_params.validate!)
    if @article.save
      redirect_to("/articles/#{@article.id}")
    else
      render("articles/new.slang")
    end
  end

  def update
    @article = Article.find!(params[:id])
    if @article.update(article_params.validate!)
      redirect_to("/articles/#{@article.id}")
    else
      render("articles/edit.slang")
    end
  end

  def destroy
    Article.find!(params[:id]).destroy
    redirect_to("/articles")
  end
end
```

## Filters

`before_action` runs a method before the named actions. Use it to authenticate
or to load a record once:

```crystal
class ArticlesController < ApplicationController
  before_action :require_login, only: [:new, :create, :update, :destroy]
  before_action :set_article, only: [:show, :update, :destroy]

  def show
    render("articles/show.slang")
  end

  private def set_article
    @article = Article.find!(params[:id])
  end

  private def require_login
    redirect_to("/login") unless current_user?
  end
end
```

## Responding in multiple formats

`respond_with` negotiates the response format from the request's `Accept`
header, so one action can serve HTML and JSON:

```crystal
class ArticlesController < ApplicationController
  def show
    @article = Article.find!(params[:id])
    respond_with do
      html render("articles/show.slang")
      json @article.to_json
    end
  end
end
```

## Strong parameters

Whitelist the attributes an action accepts before passing them to a model:

```crystal
class ArticlesController < ApplicationController
  def create
    article = Article.new(article_params.validate!)
    article.save
    redirect_to("/articles/#{article.id}")
  end

  private def article_params
    params.validation do
      required(:title) { |t| !t.nil? && !t.empty? }
      optional(:body)
    end
  end
end
```
